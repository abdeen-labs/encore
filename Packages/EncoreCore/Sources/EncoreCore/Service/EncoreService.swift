import Foundation
import Observation

/// The one place all generation goes through. The app, the CLI and (later) the local HTTP API call these methods;
/// each returns an `AsyncThrowingStream` of the request's events and ends with the finished record.
///
/// Canceling the task that consumes a stream stops the engine at its next check, deletes every temporary file
/// and writes no history record. Requests run one at a time on the GPU (see `ModelRuntime`); a request that is
/// waiting shows up as queued in `runtime.status`.
///
/// Backends are tried in order — the list given at init, with the user's runtime preference for the model moved to
/// the front — and the first that is ready and supports what the request needs is used. If it throws
/// `EngineError.unsupported` at run time, the next capable backend takes over.
public final class EncoreService: Sendable, Observable {
    public let catalog: ModelCatalog
    public let history: HistoryDatabase
    public let voices: VoiceLibrary
    public let pronunciations: PronunciationStore
    public let settings: AppSettings
    public let hub: HubLocalStore
    public let backends: [any EngineBackend]
    public let runtime: ModelRuntime
    /// Temporary files (prepared audio, trimmed references, design candidates). Swept of old leftovers at init.
    public let scratchDirectory: URL
    /// Where renders made with `saveToHistory: false` land. Callers delete their files; leftovers are swept after a day.
    public var unsavedDirectory: URL { scratchDirectory.appendingPathComponent("Unsaved", isDirectory: true) }
    let lineCache = RenderCache()

    public init(catalog: ModelCatalog, history: HistoryDatabase, voices: VoiceLibrary, pronunciations: PronunciationStore,
                settings: AppSettings, hub: HubLocalStore = HubLocalStore(), backends: [any EngineBackend],
                runtime: ModelRuntime? = nil, scratchDirectory: URL? = nil) {
        self.catalog = catalog
        self.history = history
        self.voices = voices
        self.pronunciations = pronunciations
        self.settings = settings
        self.hub = hub
        self.backends = backends
        self.runtime = runtime ?? ModelRuntime(idleMinutes: { settings.snapshot().idleUnloadMinutes })
        let scratch = scratchDirectory ?? EncorePaths.scratch.appendingPathComponent("Service", isDirectory: true)
        self.scratchDirectory = scratch
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Self.sweepScratch(scratch, olderThan: 24 * 3600)
    }

    // MARK: - Models and runtimes

    public func manifest(_ modelID: String) throws -> ModelManifest {
        guard let m = catalog.model(modelID) else { throw ServiceError.unknownModel(modelID) }
        return m
    }

    func manifest(_ modelID: String, for task: ModelTask) throws -> ModelManifest {
        let m = try manifest(modelID)
        guard m.tasks.contains(task) else { throw ServiceError.wrongTask(modelID: m.id, modelName: m.name, task: task) }
        return m
    }

    /// Where the variant's weights are, or `modelNotDownloaded`. Snapshots downloaded by other tools whose file
    /// list Encore hasn't recorded are accepted when every repo has one (the backend reports anything missing).
    public func loadContext(_ manifest: ModelManifest, variantID: String?) throws -> ModelLoadContext {
        let variant = manifest.variant(variantID)
        if let id = variantID, !manifest.variants.contains(where: { $0.id == id }) {
            throw ServiceError.invalidRequest("\(manifest.name) has no variant “\(id)”.")
        }
        let status = hub.status(of: variant)
        if let dirs = status.repoDirectories { return ModelLoadContext(manifest: manifest, variant: variant, repoDirectories: dirs) }
        let unverifiedButPresent = status.repos.allSatisfy { !$0.isVerified && $0.snapshotDirectory != nil && $0.presentFiles > 0 }
        if unverifiedButPresent {
            let dirs = Dictionary(uniqueKeysWithValues: status.repos.compactMap { r in r.snapshotDirectory.map { (r.repo, $0) } })
            return ModelLoadContext(manifest: manifest, variant: variant, repoDirectories: dirs)
        }
        throw ServiceError.modelNotDownloaded(modelID: manifest.id, variantID: variant.id, modelName: manifest.name,
                                              variantLabel: variant.label, partial: status.state == .partial)
    }

    public func isDownloaded(_ manifest: ModelManifest, variantID: String? = nil) -> Bool {
        (try? loadContext(manifest, variantID: variantID)) != nil
    }

    /// Backends able to do `needs` for this model, in the order they'll be tried. Throws when there are none,
    /// saying whether setup would help.
    public func capableBackends(for manifest: ModelManifest, needs: EngineFeatures,
                                prefers: EngineFeatures = []) async throws -> [any EngineBackend] {
        var ordered = backends
        let chosen = settings.snapshot().runtimePreference(for: manifest.id).runtime
        // A runtime picked in Settings, else the one that runs this model best.
        if let first = chosen ?? BestRuntime.pick(for: manifest.engine)?.runtime,
           let i = ordered.firstIndex(where: { $0.runtime == first }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        var ready: [any EngineBackend] = []
        // Ready backends that also offer `prefers`; they go first unless a runtime was chosen in Settings.
        var favored: [any EngineBackend] = []
        var setup: (EngineRuntime, String)?
        var unavailable: (EngineRuntime, String)?
        var supportedAnywhere: EngineFeatures = []
        for backend in ordered {
            let features = await backend.engineFeatures()[manifest.engine] ?? []
            supportedAnywhere.formUnion(features)
            guard features.isSuperset(of: needs) else { continue }
            switch await backend.availability() {
            case .ready:
                if chosen == nil, !prefers.isEmpty, features.isSuperset(of: prefers) { favored.append(backend) }
                else { ready.append(backend) }
            case .needsSetup(let m): if setup == nil { setup = (backend.runtime, m) }
            case .unavailable(let m): if unavailable == nil { unavailable = (backend.runtime, m) }
            }
        }
        ready = favored + ready
        if !ready.isEmpty { return ready }
        if let setup { throw ServiceError.backendNeedsSetup(runtime: setup.0, message: setup.1) }
        if let unavailable { throw ServiceError.backendUnavailable(runtime: unavailable.0, message: unavailable.1) }
        let missing = ServiceFeature.of(needs.subtracting(supportedAnywhere)).first
            ?? ServiceFeature.of(needs).last ?? .speech
        throw ServiceError.featureUnsupported(modelID: manifest.id, modelName: manifest.name, feature: missing,
                                              detail: needs.subtracting(supportedAnywhere).isEmpty
                                                ? "No single runtime supports everything this request needs." : nil)
    }

    /// Which runtime a model would run on for these needs ("Native" vs "Python helper"), or why none can.
    public func plannedRuntime(modelID: String, needs: EngineFeatures? = nil,
                               prefers: EngineFeatures = []) async -> Result<EngineRuntime, ServiceError> {
        do {
            let m = try manifest(modelID)
            let needs = needs ?? Self.basicNeeds(m)
            return .success(try await capableBackends(for: m, needs: needs, prefers: prefers)[0].runtime)
        } catch let e as ServiceError { return .failure(e) }
        catch { return .failure(.generationFailed(error.localizedDescription)) }
    }

    static func basicNeeds(_ m: ModelManifest) -> EngineFeatures {
        if m.tasks.contains(.tts) { return .synthesis }
        if m.tasks.contains(.stt) { return .transcription }
        return .voiceConversion
    }

    // MARK: - Streams

    /// Runs `body` in a task tied to the stream: when the consumer stops listening the task is canceled.
    func stream<Event: Sendable>(_ body: @escaping @Sendable (AsyncThrowingStream<Event, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.publicError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func publicError(_ error: Error) -> Error {
        switch error {
        case is ServiceError, is CancellationError: return error
        case let e as EngineError:
            switch e {
            case .backendUnavailable(let m): return ServiceError.generationFailed(m)
            default: return ServiceError.generationFailed(e.localizedDescription)
            }
        case let e as StoreError:
            if case .notFound(let what) = e { return ServiceError.voiceMissing(what) }
            return error
        default: return error
        }
    }

    // MARK: - Voices

    struct ResolvedVoice: Sendable {
        var engine: EngineVoice?
        var name: String?
        var libraryID: UUID?
        var isReference: Bool { engine?.referenceAudio != nil }
    }

    /// Checks a selection against the model before any work starts.
    func validate(_ selection: VoiceSelection, for manifest: ModelManifest) throws {
        switch selection {
        case .automatic: return
        case .preset(let name):
            if !manifest.presetVoices.isEmpty, !manifest.presetVoices.contains(where: { $0.id == name }) {
                throw ServiceError.unknownPresetVoice(name: name, modelID: manifest.id)
            }
        case .library(let id):
            guard manifest.capabilities.cloning || manifest.tasks.contains(.voiceConversion) else {
                throw ServiceError.featureUnsupported(modelID: manifest.id, modelName: manifest.name, feature: .cloning,
                                                      detail: "Pick a model that clones voices, or one of its own voices.")
            }
            guard voices.voice(id) != nil else { throw ServiceError.voiceMissing("The voice") }
            guard voices.referenceAudioURL(for: id) != nil else { throw ServiceError.voiceMissing("The voice's reference clip") }
        }
    }

    /// The engine's view of a voice. A reference longer than the model takes is cut at a pause near the limit; when the
    /// model reads the reference transcript, the cut clip is re-transcribed so words and audio still match (or the
    /// transcript is dropped if no transcription model is downloaded).
    func resolve(_ selection: VoiceSelection, for manifest: ModelManifest, job: RuntimeJob, temp: TempFiles) async throws -> ResolvedVoice {
        switch selection {
        case .automatic: return ResolvedVoice()
        case .preset(let name):
            return ResolvedVoice(engine: EngineVoice(preset: name), name: manifest.presetVoices.first { $0.id == name }?.name ?? name)
        case .library(let id):
            guard let voice = voices.voice(id), var engine = try voices.engineVoice(for: selection) else {
                throw ServiceError.voiceMissing("The voice")
            }
            if let spec = manifest.reference, let ref = engine.referenceAudio {
                let duration = try await AudioReader.probe(ref).duration
                if duration > spec.maxSeconds + 0.05 {
                    let trimmed = try await trimReference(ref, spec: spec, temp: temp)
                    engine.referenceAudio = trimmed
                    if let full = engine.referenceText, spec.transcript != .unused {
                        // Some transcription models need the language spelled out; the full transcript names it.
                        let language = voice.language ?? LanguageGuess.code(for: full)
                        engine.referenceText = try? await transcribeClip(trimmed, language: language, job: job, temp: temp)?.text
                    }
                }
            }
            return ResolvedVoice(engine: engine, name: voice.name, libraryID: id)
        }
    }

    /// The longest start of the clip that ends in a pause and stays under `spec.maxSeconds`.
    func trimReference(_ url: URL, spec: ReferenceSpec, temp: TempFiles) async throws -> URL {
        let buffer = try await AudioReader.read(url, range: 0...spec.maxSeconds)
        var cut = buffer.duration
        let options = SpeechSegmenter.Options(maxDuration: max(spec.minSeconds + 0.5, spec.maxSeconds - 0.5),
                                              minDuration: spec.minSeconds)
        if let first = SpeechSegmenter.segment(buffer, options: options).first, first.endsInPause, first.end < buffer.duration {
            cut = first.end
        }
        let out = temp.url("reference-\(UUID().uuidString).wav")
        try AudioExporter.writeWAV(AudioEdit.fade(AudioEdit.trim(buffer, to: 0...cut), out: 0.02), to: out, encoding: .float32)
        return out
    }

    // MARK: - Writing results

    /// Writes the master next to the history database and inserts the record. Nothing is left behind on failure
    /// or cancellation; once the record is in, the generation counts as finished. With `save` false the audio goes
    /// to `unsavedDirectory` instead and no record is inserted (the caller owns the file).
    func commit(_ audio: AudioBuffer, save: Bool = true, record make: (URL) -> GenerationRecord) async throws -> GenerationRecord {
        try Task.checkCancellation()
        let id = UUID()
        guard save else {
            try FileManager.default.createDirectory(at: unsavedDirectory, withIntermediateDirectories: true)
            let url = unsavedDirectory.appendingPathComponent("\(id.uuidString).wav")
            do {
                try AudioExporter.writeWAV(audio, to: url, encoding: .pcm24)
                try Task.checkCancellation()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            var record = make(url)
            record.id = id
            return record
        }
        let url = history.newAudioURL(id: id)
        let partial = url.deletingLastPathComponent().appendingPathComponent(".\(id.uuidString).partial.wav")
        do {
            try AudioExporter.writeWAV(audio, to: partial, encoding: .pcm24)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: partial, to: url)
            var record = make(url)
            record.id = id
            try Task.checkCancellation()
            try await history.insert(record)
            return record
        } catch {
            try? FileManager.default.removeItem(at: partial)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func noteUsed(_ modelID: String, for feature: AppSettings.Feature) async {
        let settings = self.settings
        await MainActor.run { settings.noteModelUsed(modelID, for: feature) }
    }

    func libraryVoices() async -> [Voice] {
        let voices = self.voices
        return await MainActor.run { voices.voices }
    }

    static func sweepScratch(_ dir: URL, olderThan age: TimeInterval) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        guard let items = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for case let url as URL in items {
            if let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func title(from text: String, fallback: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        guard !words.isEmpty else { return fallback }
        return words.count > 60 ? String(words.prefix(60)) + "…" : words
    }
}

// MARK: - Helpers

/// Temporary files for one request; all deleted when the request ends, however it ends.
final class TempFiles: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var urls: [URL] = []

    init(in parent: URL) {
        directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL {
        let u = directory.appendingPathComponent(name)
        lock.withLock { urls.append(u) }
        return u
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Sends stage/progress to both the event stream and the runtime status.
struct Reporter<Event: Sendable>: Sendable {
    let job: RuntimeJob
    let continuation: AsyncThrowingStream<Event, Error>.Continuation
    let stageEvent: @Sendable (String) -> Event
    let progressEvent: @Sendable (Double) -> Event
    private let last = ProgressMemo()

    init(job: RuntimeJob, continuation: AsyncThrowingStream<Event, Error>.Continuation,
         stageEvent: @escaping @Sendable (String) -> Event, progressEvent: @escaping @Sendable (Double) -> Event) {
        self.job = job; self.continuation = continuation; self.stageEvent = stageEvent; self.progressEvent = progressEvent
    }

    func stage(_ text: String) async {
        await job.stage(text)
        continuation.yield(stageEvent(text))
    }

    func progress(_ value: Double) async {
        let v = min(1, max(0, value))
        guard last.advance(to: v) else { return }
        await job.progress(v)
        continuation.yield(progressEvent(v))
    }

    /// A synchronous callback for engines, mapped into `range` of the overall progress.
    func engineProgress(_ range: ClosedRange<Double>) -> EngineProgress {
        let job = self.job, c = continuation, make = progressEvent, last = self.last
        return { p in
            let v = range.lowerBound + (range.upperBound - range.lowerBound) * min(1, max(0, p))
            guard last.advance(to: v) else { return }
            c.yield(make(v))
            Task { await job.progress(v) }
        }
    }
}

/// Keeps progress events moving forward and drops repeats.
final class ProgressMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0
    func advance(to v: Double) -> Bool {
        lock.withLock {
            guard v > value + 0.0005 else { return false }
            value = v
            return true
        }
    }
}

/// One request's use of a model: picks the backend, loads through the governor, and falls through to the next
/// capable backend when one says `.unsupported` at run time.
final class EngineSession: @unchecked Sendable {
    let candidates: [any EngineBackend]
    let context: ModelLoadContext
    let job: RuntimeJob
    let feature: ServiceFeature
    let onLoading: @Sendable (String) async -> Void
    private var index = 0
    private(set) var fallbacks: [String] = []

    init(candidates: [any EngineBackend], context: ModelLoadContext, job: RuntimeJob, feature: ServiceFeature,
         onLoading: @escaping @Sendable (String) async -> Void) {
        self.candidates = candidates; self.context = context; self.job = job; self.feature = feature; self.onLoading = onLoading
    }

    var runtime: EngineRuntime { candidates[index].runtime }

    func run<T>(_ operation: (any EngineBackend) async throws -> T) async throws -> T {
        while true {
            let backend = candidates[index]
            do {
                if !(await job.isLoaded(context, on: backend)) {
                    let suffix = candidates.count > 1 || backend.runtime == .python ? " (\(backend.runtime.displayName))" : ""
                    await onLoading("Loading \(context.manifest.name)…" + suffix)
                }
                try await job.ensureLoaded(context, on: backend)
                return try await operation(backend)
            } catch EngineError.unsupported(let message) {
                try Task.checkCancellation()
                guard index + 1 < candidates.count else {
                    throw ServiceError.featureUnsupported(modelID: context.manifest.id, modelName: context.manifest.name,
                                                          feature: feature, detail: message)
                }
                fallbacks.append("\(backend.runtime.rawValue): \(message)")
                index += 1
            }
        }
    }
}

/// Recently rendered conversation lines, so re-rendering after an edit only regenerates what changed.
actor RenderCache {
    private var items: [String: (audio: AudioBuffer, used: Date)] = [:]
    /// Total audio kept, seconds.
    let capacity: TimeInterval

    init(capacity: TimeInterval = 20 * 60) { self.capacity = capacity }

    func get(_ key: String) -> AudioBuffer? {
        guard let hit = items[key] else { return nil }
        items[key] = (hit.audio, Date())
        return hit.audio
    }

    func put(_ key: String, _ audio: AudioBuffer) {
        items[key] = (audio, Date())
        var total = items.values.reduce(0) { $0 + $1.audio.duration }
        for (k, v) in items.sorted(by: { $0.value.used < $1.value.used }) where total > capacity && k != key {
            items[k] = nil
            total -= v.audio.duration
        }
    }

    func removeAll() { items = [:] }
    var count: Int { items.count }
}
