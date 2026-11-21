import Foundation
import Testing
@testable import EncoreCore

/// The memory governor and job queue.
@Suite struct ServiceRuntimeTests {
    static func context(_ id: String, memory: Int64) -> ModelLoadContext {
        let m = testManifest(id, memory: memory)
        return ModelLoadContext(manifest: m, variant: m.defaultVariant, repoDirectories: [:])
    }

    final class Minutes: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(_ v: Int) { value = v }
        var get: Int { lock.withLock { value } }
        func set(_ v: Int) { lock.withLock { value = v } }
    }

    func runtime(minutes: Minutes = Minutes(10), clock: TestClock = TestClock(),
                 memory: SystemMemory = SystemMemory(physicalBytes: 20 * GB, availableBytes: 18 * GB)) -> ModelRuntime {
        ModelRuntime(memory: FixedMemory(memory: memory), idleMinutes: { minutes.get }, now: { clock.now }, autoSweep: false)
    }

    /// Runs one job that loads the given models.
    func use(_ runtime: ModelRuntime, _ contexts: [ModelLoadContext], on backend: FakeBackend) async throws {
        let m = contexts[0].manifest
        try await runtime.run(.speech, title: "t", model: m) { job in
            for c in contexts { try await job.ensureLoaded(c, on: backend) }
        }
    }

    @Test func idleModelsUnloadAfterTheSetting() async throws {
        let clock = TestClock(), minutes = Minutes(10)
        let rt = runtime(minutes: minutes, clock: clock)
        let b = FakeBackend(.mlxSwift, features: [:])
        try await use(rt, [Self.context("a", memory: 1 * GB)], on: b)
        clock.advance(minutes: 9)
        await rt.sweepIdle()
        #expect(await rt.isLoaded(modelID: "a"))
        let unloadsAt = try #require(await rt.loadedModels().first?.unloadsAt)
        #expect(unloadsAt.timeIntervalSince(clock.now) < 61)
        clock.advance(minutes: 1.5)
        await rt.sweepIdle()
        #expect(await !rt.isLoaded(modelID: "a"))
        #expect(b.unloads == ["a"])
        #expect(await rt.snapshot().recentUnloads.last?.reason == "idle for 10 min")

        // 0 = never.
        minutes.set(0)
        try await use(rt, [Self.context("a", memory: 1 * GB)], on: b)
        clock.advance(minutes: 600)
        await rt.sweepIdle()
        #expect(await rt.isLoaded(modelID: "a"))
        // Changing the setting takes effect immediately.
        minutes.set(5)
        await rt.settingsChanged()
        #expect(await !rt.isLoaded(modelID: "a"))
    }

    @Test func leastRecentlyUsedIdleModelMakesRoom() async throws {
        let clock = TestClock()
        let rt = runtime(clock: clock)  // 20 GB Mac: 15 GB budget
        let b = FakeBackend(.mlxSwift, features: [:])
        try await use(rt, [Self.context("a", memory: 6 * GB)], on: b)
        clock.advance(minutes: 1)
        try await use(rt, [Self.context("b", memory: 6 * GB)], on: b)
        clock.advance(minutes: 1)
        try await use(rt, [Self.context("a", memory: 6 * GB)], on: b)  // a is now the most recently used
        clock.advance(minutes: 1)
        let c = Self.context("c", memory: 6 * GB)
        let assessment = await rt.assess(c.manifest, c.variant)
        #expect(assessment.verdict == .comfortable && assessment.wouldUnload == ["B"])
        try await use(rt, [c], on: b)
        #expect(b.unloads == ["b"])
        #expect(Set(await rt.loadedModels().map(\.modelID)) == ["a", "c"])
        #expect(await rt.snapshot().recentUnloads.last?.reason == "to make room for C")
    }

    @Test func busyModelsAreNeverEvicted() async throws {
        let rt = runtime()
        let b = FakeBackend(.mlxSwift, features: [:])
        // One job holds a and b, then needs c: nothing idle to unload, so c loads next to them.
        try await use(rt, [Self.context("a", memory: 6 * GB), Self.context("b", memory: 6 * GB), Self.context("c", memory: 6 * GB)], on: b)
        #expect(b.unloads.isEmpty)
        #expect(Set(await rt.loadedModels().map(\.modelID)) == ["a", "b", "c"])

        // A manual unload of a busy model waits for its job to end.
        try await rt.run(.speech, title: "t", model: Self.context("a", memory: 0).manifest) { job in
            try await job.ensureLoaded(Self.context("a", memory: 6 * GB), on: b)
            await rt.unload(modelID: "a")
            #expect(await rt.isLoaded(modelID: "a"))
            #expect(await rt.loadedModels().first { $0.modelID == "a" }?.isBusy == true)
        }
        #expect(await !rt.isLoaded(modelID: "a"))
        await rt.unloadAll()
        #expect(await rt.loadedModels().isEmpty)
    }

    @Test func fitAssessmentThresholds() {
        let p = MemoryPolicy()
        let mac16 = { (available: Int64, pressure: MemoryPressure) in
            SystemMemory(physicalBytes: 16 * GB, availableBytes: available, pressure: pressure)
        }
        // 16 GB: budget 12 GB, headroom 2 GB.
        #expect(p.verdict(need: 13 * GB, loaded: 0, evictable: 0, memory: mac16(15 * GB, .normal)).0 == .wontFit)
        #expect(p.verdict(need: 4 * GB, loaded: 0, evictable: 0, memory: mac16(10 * GB, .normal)) == (.comfortable, false))
        #expect(p.verdict(need: 4 * GB, loaded: 0, evictable: 0, memory: mac16(10 * GB, .warning)).0 == .tight)
        #expect(p.verdict(need: 6 * GB, loaded: 8 * GB, evictable: 8 * GB, memory: mac16(4 * GB, .normal)) == (.comfortable, true))
        #expect(p.verdict(need: 6 * GB, loaded: 0, evictable: 0, memory: mac16(7 * GB, .normal)).0 == .tight)
        #expect(p.verdict(need: 9 * GB, loaded: 0, evictable: 0, memory: mac16(2 * GB, .normal)).0 == .wontFit)
        // Loaded models that are busy count against the budget.
        #expect(p.verdict(need: 6 * GB, loaded: 8 * GB, evictable: 0, memory: mac16(8 * GB, .normal)).0 == .tight)
    }

    @Test func assessmentReportsNumbersAndAlreadyLoaded() async throws {
        let rt = runtime(memory: SystemMemory(physicalBytes: 48 * GB, availableBytes: 30 * GB))
        let c = Self.context("q", memory: 9 * GB)
        let a = await rt.assess(c.manifest, c.variant)
        #expect(a.verdict == .comfortable && !a.alreadyLoaded)
        #expect(a.requiredBytes == 9 * GB && a.budgetBytes == 36 * GB && a.headroomBytes == Int64(4.8 * Double(GB)))
        #expect(a.summary.contains("free"))
        try await use(rt, [c], on: FakeBackend(.mlxSwift, features: [:]))
        #expect(await rt.assess(c.manifest, c.variant).alreadyLoaded)
        let huge = Self.context("huge", memory: 40 * GB)
        let h = await rt.assess(huge.manifest, huge.variant)
        #expect(h.verdict == .wontFit && h.summary.contains("smaller variant"))
    }

    @Test func jobsRunOneAtATimeAndQueueVisibly() async throws {
        let rt = runtime()
        let m = testManifest("m")
        let gate = AsyncStream<Void>.makeStream()
        let first = Task { try await rt.run(.speech, title: "first", model: m) { _ in for await _ in gate.stream { break } } }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await rt.run(.transcription, title: "second", model: m) { _ in } }
        let third = Task { try await rt.run(.voiceDesign, title: "third", model: m) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        var jobs = await rt.snapshot().jobs
        #expect(jobs.map(\.title) == ["first", "second", "third"])
        #expect(jobs.map(\.state) == [.running, .queued, .queued])
        // A queued job that's canceled leaves the queue.
        third.cancel()
        await #expect(throws: CancellationError.self) { try await third.value }
        jobs = await rt.snapshot().jobs
        #expect(jobs.map(\.title) == ["first", "second"])
        gate.continuation.yield()
        try await first.value
        try await second.value
        await rt.waitUntilIdle()
        #expect(await rt.snapshot().jobs.isEmpty)
    }

    @Test @MainActor func statusObjectFollowsTheRuntime() async throws {
        let status = RuntimeStatus(memory: SystemMemory(physicalBytes: 1, availableBytes: 1))
        let rt = ModelRuntime(memory: FixedMemory(memory: SystemMemory(physicalBytes: 20 * GB, availableBytes: 18 * GB)),
                              idleMinutes: { 10 }, status: status, autoSweep: false)
        let b = FakeBackend(.mlxSwift, features: [:])
        let c = Self.context("a", memory: 2 * GB)
        try await rt.run(.speech, title: "Hello", model: c.manifest) { job in
            try await job.ensureLoaded(c, on: b)
            await job.stage("Generating 1 of 2")
            await job.progress(0.5)
            try await Task.sleep(for: .milliseconds(30))
            await MainActor.run {
                #expect(status.runningJob?.stage == "Generating 1 of 2")
                #expect(status.runningJob?.progress == 0.5)
                #expect(status.runningJob?.runtime == .mlxSwift)
                #expect(status.isBusy)
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(!status.isBusy)
        #expect(status.loaded.map(\.modelID) == ["a"])
        #expect(status.loadedBytes == 2 * GB)
        #expect(status.memory.physicalBytes == 20 * GB)
    }
}
