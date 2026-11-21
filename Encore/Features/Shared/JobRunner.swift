import EncoreCore
import SwiftUI

/// Events from any service stream, reduced to what a progress display needs.
protocol JobEvent: Sendable {
    var stageText: String? { get }
    var fraction: Double? { get }
}

extension GenerationEvent: JobEvent {
    var stageText: String? { if case .stage(let s) = self { s } else { nil } }
    var fraction: Double? { if case .progress(let p) = self { p } else { nil } }
}

extension TranscriptionEvent: JobEvent {
    var stageText: String? { if case .stage(let s) = self { s } else { nil } }
    var fraction: Double? { if case .progress(let p) = self { p } else { nil } }
}

extension VoiceDesignEvent: JobEvent {
    var stageText: String? { if case .stage(let s) = self { s } else { nil } }
    var fraction: Double? { if case .progress(let p) = self { p } else { nil } }
}

/// One screen's way to start, watch and cancel a service job, with the memory check before it starts.
/// Pair it with `RunSurface` for the UI and `ServiceErrorBanner(error:)` for failures.
///
///     let runner = JobRunner(runtime: service.runtime)
///     runner.start(.speech, model: manifest, variantID: choice.variantID) {
///         service.speak(request)
///     } onEvent: { event in
///         if case .finished(let record) = event { … }
///     }
///
/// - Before starting it asks `ModelRuntime.assess`. Comfortable (or already loaded) → it runs. Tight or won't fit →
///   `phase` becomes `.confirmMemory(assessment)` and nothing happens until `runAnyway()` or `dismissMemoryWarning()`.
/// - `cancel()` stops the job (the service deletes its temporary files and writes no record).
/// - A failure lands in `error` (cancellation never does); set it to nil to dismiss.
@MainActor @Observable
final class JobRunner {
    enum Phase: Equatable {
        case idle
        case checkingMemory
        case confirmMemory(MemoryAssessment)
        case running
    }

    enum Outcome: Equatable {
        case finished(elapsed: TimeInterval)
        case canceled
        case failed
    }

    /// What the runner is working on, for matching it in `RuntimeStatus` (queue position).
    struct Identity: Equatable {
        var kind: JobKind
        var modelID: String
        var modelName: String
    }

    private(set) var phase: Phase = .idle
    /// The latest stage message ("Loading Soprano…", "Generating 2 of 5").
    private(set) var stage: String?
    /// 0…1, nil until the job reports progress.
    private(set) var progress: Double?
    private(set) var startedAt: Date?
    private(set) var identity: Identity?
    /// How the last job ended.
    private(set) var lastOutcome: Outcome?
    /// The last failure. Present with `ServiceErrorBanner`; set to nil to dismiss.
    var error: Error?

    var isBusy: Bool { phase != .idle }
    var isRunning: Bool { phase == .running }
    /// True once the job has left the queue and reported something.
    var hasStarted: Bool { stage != nil || progress != nil }

    let runtime: ModelRuntime
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: (() -> Void)?
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Every runner alive, so Settings → Reset can stop them all.
    private static let all = NSHashTable<JobRunner>.weakObjects()

    init(runtime: ModelRuntime) {
        self.runtime = runtime
        Self.all.add(self)
    }

    /// Cancels every runner's job (Settings → Reset, before deleting anything).
    static func cancelAll() {
        for runner in all.allObjects { runner.cancel() }
    }

    /// Starts a job (after the memory check). Ignored while another job of this runner is busy.
    /// - Parameters:
    ///   - checkMemory: false skips `assess` (e.g. the model is known to be loaded, or the job loads nothing).
    ///   - stream: called once, when the job really starts.
    ///   - onEvent: every event, on the main actor, before the runner updates its own state.
    func start<E: JobEvent>(_ kind: JobKind, model: ModelManifest, variantID: String?, checkMemory: Bool = true,
                            stream: @escaping @MainActor () -> AsyncThrowingStream<E, Error>,
                            onEvent: @escaping @MainActor (E) -> Void = { _ in }) {
        guard !isBusy else { return }
        error = nil
        identity = Identity(kind: kind, modelID: model.id, modelName: model.name)
        let go: () -> Void = { [weak self] in self?.launch(stream: stream, onEvent: onEvent) }
        guard checkMemory else { go(); return }
        phase = .checkingMemory
        let variant = model.variant(variantID)
        task = Task { [weak self] in
            guard let self else { return }
            let assessment = await self.runtime.assess(model, variant)
            guard self.phase == .checkingMemory else { return }
            if assessment.alreadyLoaded || assessment.verdict == .comfortable {
                go()
            } else {
                self.pending = go
                self.phase = .confirmMemory(assessment)
            }
        }
    }

    /// The user chose to load despite the memory warning.
    func runAnyway() {
        guard case .confirmMemory = phase, let go = pending else { return }
        pending = nil
        go()
    }

    /// The user backed out at the memory warning.
    func dismissMemoryWarning() {
        guard case .confirmMemory = phase else { return }
        pending = nil
        finish(nil)
    }

    /// Cancels whatever is happening (waiting in the queue, loading, generating).
    func cancel() {
        switch phase {
        case .idle: return
        case .confirmMemory: dismissMemoryWarning()
        case .checkingMemory, .running:
            task?.cancel()
            if phase == .checkingMemory { finish(.canceled) }
        }
    }

    /// Returns when the runner is idle again (the headless runner and tests use this).
    func waitUntilIdle() async {
        guard isBusy else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    // MARK: Private

    private func launch<E: JobEvent>(stream: @escaping @MainActor () -> AsyncThrowingStream<E, Error>,
                                     onEvent: @escaping @MainActor (E) -> Void) {
        phase = .running
        stage = nil
        progress = nil
        startedAt = Date()
        task = Task { [weak self] in
            let events = stream()
            do {
                for try await event in events {
                    onEvent(event)
                    guard let self else { return }
                    if let s = event.stageText { self.stage = s }
                    if let p = event.fraction { self.progress = p }
                }
                guard let self else { return }
                if Task.isCancelled {
                    self.finish(.canceled)
                } else {
                    self.finish(.finished(elapsed: Date().timeIntervalSince(self.startedAt ?? Date())))
                }
            } catch is CancellationError {
                self?.finish(.canceled)
            } catch {
                guard let self else { return }
                if Task.isCancelled { self.finish(.canceled); return }
                self.error = error
                self.finish(.failed)
            }
        }
    }

    private func finish(_ outcome: Outcome?) {
        if let outcome { lastOutcome = outcome }
        phase = .idle
        stage = nil
        progress = nil
        task = nil
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    #if DEBUG
    /// Fixtures: show a state without running anything.
    func debugShow(_ phase: Phase, identity: Identity?, stage: String? = nil, progress: Double? = nil,
                   startedAt: Date? = nil, error: Error? = nil, lastOutcome: Outcome? = nil) {
        self.phase = phase
        self.identity = identity
        self.stage = stage
        self.progress = progress
        self.startedAt = startedAt
        self.error = error
        self.lastOutcome = lastOutcome
    }
    #endif
}
