import Foundation

/// The memory governor and GPU job queue. Owns loading and unloading across every backend:
///
/// - Jobs run one at a time in arrival order (`run(_:_:)`); later ones wait in a visible queue and leave it when canceled.
/// - Inside a job, `RuntimeJob.ensureLoaded` loads the model on the chosen backend, first unloading least-recently-used
///   idle models when the new one wouldn't otherwise fit (`MemoryPolicy`). A model in use by a job is never unloaded;
///   a manual unload of a busy model happens when its job ends.
/// - Idle models are unloaded after `idleMinutes()` (0 = never). The setting is re-read on every tick (at most 30 s
///   apart) and immediately after `settingsChanged()`.
/// - `assess(_:_:)` answers "will this fit?" for the UI's warning before a load.
///
/// Every method can be called from any isolation.
public final class ModelRuntime: Sendable {
    public let policy: MemoryPolicy
    public let memoryProbe: any SystemMemoryProbe
    /// Updated on the main actor whenever anything changes. Nil in headless use.
    public let status: RuntimeStatus?
    let state: State

    /// - Parameters:
    ///   - idleMinutes: current idle-unload setting (`AppSettings.snapshot().idleUnloadMinutes`).
    ///   - now: the clock; tests inject one.
    ///   - autoSweep: run the idle timer. Tests turn it off and call `sweepIdle()`.
    public init(policy: MemoryPolicy = MemoryPolicy(), memory: any SystemMemoryProbe = LiveSystemMemory(),
                idleMinutes: @escaping @Sendable () -> Int, now: @escaping @Sendable () -> Date = { Date() },
                status: RuntimeStatus? = nil, autoSweep: Bool = true) {
        self.policy = policy
        self.memoryProbe = memory
        self.status = status
        state = State(policy: policy, probe: memory, idleMinutes: idleMinutes, now: now, status: status, autoSweep: autoSweep)
    }

    // MARK: Jobs

    /// Runs `body` when the GPU slot is free. Waiting honors cancellation (the job leaves the queue).
    public func run<T: Sendable>(_ kind: JobKind, title: String, model: ModelManifest,
                                 _ body: @Sendable (RuntimeJob) async throws -> T) async throws -> T {
        let job = RuntimeJob(id: UUID(), runtime: self)
        try await state.acquire(JobStatus(id: job.id, kind: kind, title: title, modelID: model.id, modelName: model.name,
                                          state: .queued, enqueuedAt: state.now()))
        do {
            try Task.checkCancellation()
            let result = try await body(job)
            await state.release(job.id)
            return result
        } catch {
            await state.release(job.id)
            throw error
        }
    }

    /// Returns once no job is running or queued.
    public func waitUntilIdle() async { await state.waitUntilIdle() }

    // MARK: Memory

    /// Will this variant fit? Call before a load the user starts, and warn unless the verdict is `.comfortable`.
    public func assess(_ manifest: ModelManifest, _ variant: ModelVariant) async -> MemoryAssessment {
        await state.assess(manifest, variant)
    }

    public func loadedModels() async -> [LoadedModel] { await state.snapshot(refreshMemory: false).loaded }
    public func snapshot() async -> RuntimeSnapshot { await state.snapshot(refreshMemory: true) }
    public func isLoaded(modelID: String, runtime: EngineRuntime? = nil) async -> Bool {
        await state.isLoaded(modelID: modelID, runtime: runtime)
    }

    /// Unloads a model from every runtime (deferred until its job ends if it is busy).
    public func unload(modelID: String) async { await state.unload(modelID: modelID, reason: "on request") }
    public func unloadAll() async { await state.unloadAll() }

    /// Unloads models idle for longer than the setting. Runs on its own timer; tests call it directly.
    public func sweepIdle() async { await state.sweepIdle() }

    /// Re-reads the idle-unload setting now instead of at the next tick.
    public func settingsChanged() async { await state.restartTimer() }

    /// Publishes fresh system memory figures to `status`.
    public func refreshStatus() async { await state.publish(refreshMemory: true) }
}

/// A running job: report progress to the status object and load models through the governor.
public final class RuntimeJob: Sendable {
    public let id: UUID
    let runtime: ModelRuntime

    init(id: UUID, runtime: ModelRuntime) { self.id = id; self.runtime = runtime }

    /// Loads (or keeps) the context's model on `backend` and marks it busy until the job ends.
    public func ensureLoaded(_ context: ModelLoadContext, on backend: any EngineBackend) async throws {
        try await runtime.state.ensureLoaded(context, backend: backend, job: id)
    }

    public func isLoaded(_ context: ModelLoadContext, on backend: any EngineBackend) async -> Bool {
        await runtime.state.isLoaded(modelID: context.manifest.id, variantID: context.variant.id, runtime: backend.runtime)
    }

    public func stage(_ text: String) async { await runtime.state.update(id, stage: text) }
    /// Overall progress, 0…1. Never moves backwards within a job.
    public func progress(_ value: Double) async { await runtime.state.update(id, progress: value) }
}

// MARK: - State

extension ModelRuntime {
    struct Key: Hashable, Sendable {
        var modelID: String
        var runtime: EngineRuntime
    }

    actor State {
        struct Entry {
            var manifest: ModelManifest
            var variant: ModelVariant
            var backend: any EngineBackend
            var loadedAt: Date
            var lastUsed: Date
            var busy = 0
            var unloadWhenIdle = false
            var memory: Int64 { variant.memoryBytes }
        }

        let policy: MemoryPolicy
        let probe: any SystemMemoryProbe
        let idleMinutes: @Sendable () -> Int
        nonisolated let now: @Sendable () -> Date
        let status: RuntimeStatus?
        let autoSweep: Bool

        var entries: [Key: Entry] = [:]
        var running: JobStatus?
        var queue: [JobStatus] = []
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        var jobModels: [UUID: Set<Key>] = [:]
        var idleWaiters: [CheckedContinuation<Void, Never>] = []
        var recentUnloads: [UnloadEvent] = []
        var timer: Task<Void, Never>?
        var version = 0
        var memory: SystemMemory
        var memoryReadAt = Date.distantPast

        init(policy: MemoryPolicy, probe: any SystemMemoryProbe, idleMinutes: @escaping @Sendable () -> Int,
             now: @escaping @Sendable () -> Date, status: RuntimeStatus?, autoSweep: Bool) {
            self.policy = policy; self.probe = probe; self.idleMinutes = idleMinutes; self.now = now
            self.status = status; self.autoSweep = autoSweep
            memory = probe.read()
        }

        // MARK: Queue

        func acquire(_ job: JobStatus) async throws {
            var job = job
            if running == nil, queue.isEmpty {
                job.state = .running; job.startedAt = now()
                running = job
                publish()
                return
            }
            queue.append(job)
            publish()
            let id = job.id
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled { dropQueued(id); c.resume(throwing: CancellationError()) }
                    else { waiters[id] = c }
                }
            } onCancel: {
                Task { await self.cancelQueued(id) }
            }
        }

        private func dropQueued(_ id: UUID) {
            queue.removeAll { $0.id == id }
            publish()
            resumeIdleWaitersIfIdle()
        }

        func cancelQueued(_ id: UUID) {
            guard let c = waiters.removeValue(forKey: id) else { return }
            dropQueued(id)
            c.resume(throwing: CancellationError())
        }

        func release(_ id: UUID) async {
            // The job's models become idle (and are unloaded now if that was asked for while busy).
            for key in jobModels.removeValue(forKey: id) ?? [] {
                guard var e = entries[key] else { continue }
                e.busy = max(0, e.busy - 1)
                e.lastUsed = now()
                entries[key] = e
                if e.busy == 0, e.unloadWhenIdle { await remove(key, reason: "on request") }
            }
            if running?.id == id { running = nil }
            if running == nil, !queue.isEmpty {
                var next = queue.removeFirst()
                next.state = .running; next.startedAt = now()
                running = next
                waiters.removeValue(forKey: next.id)?.resume()
            }
            publish()
            resumeIdleWaitersIfIdle()
            startTimerIfNeeded()
        }

        func waitUntilIdle() async {
            if running == nil, queue.isEmpty { return }
            await withCheckedContinuation { idleWaiters.append($0) }
        }

        private func resumeIdleWaitersIfIdle() {
            guard running == nil, queue.isEmpty else { return }
            let w = idleWaiters
            idleWaiters = []
            w.forEach { $0.resume() }
        }

        func update(_ id: UUID, stage: String? = nil, progress: Double? = nil, runtime: EngineRuntime? = nil) {
            guard running?.id == id else { return }
            if let stage { running?.stage = stage }
            if let progress { let current = running?.progress ?? 0; running?.progress = max(current, min(1, max(0, progress))) }
            if let runtime { running?.runtime = runtime }
            publish()
        }

        // MARK: Loading

        func isLoaded(modelID: String, variantID: String? = nil, runtime: EngineRuntime?) -> Bool {
            entries.contains { k, e in
                k.modelID == modelID && (runtime == nil || k.runtime == runtime) && (variantID == nil || e.variant.id == variantID)
            }
        }

        func ensureLoaded(_ context: ModelLoadContext, backend: any EngineBackend, job: UUID) async throws {
            let key = Key(modelID: context.manifest.id, runtime: backend.runtime)
            update(job, runtime: backend.runtime)
            if var e = entries[key], e.variant.id == context.variant.id {
                if jobModels[job, default: []].insert(key).inserted { e.busy += 1 }
                e.lastUsed = now()
                e.unloadWhenIdle = false
                entries[key] = e
                publish()
                return
            }
            // A different variant of the same model on this backend: the backend replaces it on load.
            if entries.removeValue(forKey: key) != nil { record(key, reason: "replaced by \(context.variant.label)") }
            await makeRoom(for: context.variant.memoryBytes, excluding: key, forName: context.manifest.name)
            try Task.checkCancellation()
            do {
                try await backend.load(context)
            } catch {
                publish()
                throw error
            }
            let t = now()
            entries[key] = Entry(manifest: context.manifest, variant: context.variant, backend: backend, loadedAt: t, lastUsed: t, busy: 1)
            jobModels[job, default: []].insert(key)
            publish(refreshMemory: true)
            startTimerIfNeeded()
        }

        /// Unloads least-recently-used idle models until `need` fits comfortably (or nothing idle is left).
        private func makeRoom(for need: Int64, excluding: Key, forName name: String) async {
            let mem = probe.read()
            var loaded = entries.filter { $0.key != excluding }.reduce(Int64(0)) { $0 + $1.value.memory }
            var freed: Int64 = 0
            let idle = entries.filter { $0.key != excluding && $0.value.busy == 0 }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            for (key, entry) in idle {
                if policy.fitsComfortably(need: need, loaded: loaded, available: mem.availableBytes + freed, physical: mem.physicalBytes) {
                    break
                }
                await remove(key, reason: "to make room for \(name)")
                loaded -= entry.memory
                freed += entry.memory
            }
        }

        private func remove(_ key: Key, reason: String) async {
            guard let e = entries.removeValue(forKey: key) else { return }
            record(key, reason: reason)
            publish()
            await e.backend.unload(modelID: key.modelID)
            publish(refreshMemory: true)
        }

        private func record(_ key: Key, reason: String) {
            recentUnloads.append(UnloadEvent(modelID: key.modelID, runtime: key.runtime, reason: reason, at: now()))
            if recentUnloads.count > 20 { recentUnloads.removeFirst(recentUnloads.count - 20) }
        }

        func unload(modelID: String, reason: String) async {
            for key in entries.keys where key.modelID == modelID {
                if entries[key]!.busy > 0 { entries[key]!.unloadWhenIdle = true } else { await remove(key, reason: reason) }
            }
            publish()
        }

        func unloadAll() async {
            for key in Array(entries.keys) {
                if let e = entries[key], e.busy > 0 { entries[key]!.unloadWhenIdle = true; continue }
                await remove(key, reason: "on request")
            }
            publish()
        }

        // MARK: Idle unloading

        private func idleSeconds() -> TimeInterval? {
            let minutes = idleMinutes()
            return minutes > 0 ? TimeInterval(minutes) * 60 : nil
        }

        func sweepIdle() async {
            guard let limit = idleSeconds() else { return }
            let t = now()
            for (key, e) in entries where e.busy == 0 && t.timeIntervalSince(e.lastUsed) >= limit {
                await remove(key, reason: "idle for \(Int(limit / 60)) min")
            }
        }

        /// Seconds until the next idle deadline, capped so a changed setting is noticed; nil when nothing is loaded.
        private func nextTick() -> TimeInterval? {
            guard !entries.isEmpty else { return nil }
            guard let limit = idleSeconds() else { return 30 }
            let t = now()
            let soonest = entries.values.filter { $0.busy == 0 }.map { limit - t.timeIntervalSince($0.lastUsed) }.min() ?? 30
            return min(30, max(1, soonest + 0.5))
        }

        func startTimerIfNeeded() {
            guard autoSweep, timer == nil, !entries.isEmpty else { return }
            timer = Task { [weak self] in
                while let self, let delay = await self.nextTick() {
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { return }
                    await self.sweepIdle()
                    await self.publish(refreshMemory: true)
                }
                await self?.timerEnded()
            }
        }

        private func timerEnded() { timer = nil }

        func restartTimer() async {
            timer?.cancel()
            timer = nil
            await sweepIdle()
            startTimerIfNeeded()
            publish()
        }

        // MARK: Assessment and status

        func assess(_ manifest: ModelManifest, _ variant: ModelVariant) -> MemoryAssessment {
            let mem = probe.read()
            let already = entries.contains { $0.key.modelID == manifest.id && $0.value.variant.id == variant.id }
            let others = entries.filter { $0.key.modelID != manifest.id }
            let loaded = others.reduce(Int64(0)) { $0 + $1.value.memory }
            let idle = others.filter { $0.value.busy == 0 }.sorted { $0.value.lastUsed < $1.value.lastUsed }
            let evictable = idle.reduce(Int64(0)) { $0 + $1.value.memory }
            let (verdict, unloads) = already ? (.comfortable, false)
                : policy.verdict(need: variant.memoryBytes, loaded: loaded, evictable: evictable, memory: mem)
            var wouldUnload: [String] = []
            if unloads {
                // Exactly the models makeRoom would take, in order.
                var l = loaded, freed: Int64 = 0
                for (_, e) in idle {
                    if policy.fitsComfortably(need: variant.memoryBytes, loaded: l, available: mem.availableBytes + freed,
                                              physical: mem.physicalBytes) { break }
                    wouldUnload.append(e.manifest.name); l -= e.memory; freed += e.memory
                }
            }
            return MemoryAssessment(verdict: verdict, modelID: manifest.id, variantID: variant.id, requiredBytes: variant.memoryBytes,
                                    memory: mem, loadedBytes: loaded, evictableBytes: evictable,
                                    budgetBytes: policy.budget(physical: mem.physicalBytes),
                                    headroomBytes: policy.headroom(physical: mem.physicalBytes),
                                    alreadyLoaded: already, wouldUnload: wouldUnload)
        }

        func snapshot(refreshMemory: Bool) -> RuntimeSnapshot {
            if refreshMemory || now().timeIntervalSince(memoryReadAt) > 1 {
                memory = probe.read(); memoryReadAt = now()
            }
            let limit = idleSeconds()
            let loaded = entries.map { key, e in
                LoadedModel(modelID: key.modelID, modelName: e.manifest.name, variantID: e.variant.id, variantLabel: e.variant.label,
                            runtime: key.runtime, memoryBytes: e.memory, loadedAt: e.loadedAt, lastUsed: e.lastUsed, isBusy: e.busy > 0,
                            unloadsAt: e.busy == 0 ? limit.map { e.lastUsed.addingTimeInterval($0) } : nil)
            }.sorted { $0.lastUsed > $1.lastUsed }
            version += 1
            return RuntimeSnapshot(loaded: loaded, jobs: (running.map { [$0] } ?? []) + queue, memory: memory,
                                   recentUnloads: recentUnloads, version: version)
        }

        func publish(refreshMemory: Bool = false) {
            guard let status else { return }
            let snap = snapshot(refreshMemory: refreshMemory)
            Task { @MainActor in status.apply(snap) }
        }
    }
}
