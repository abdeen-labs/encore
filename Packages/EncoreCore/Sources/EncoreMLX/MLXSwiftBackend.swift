import EncoreCore
import Foundation
import MLX
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS
import NaturalLanguage

/// Runs models in-process with MLX Swift (mlx-audio-swift).
///
/// Loads read only local snapshot directories (`ModelLoadContext.repoDirectories`); nothing touches the
/// network. All model work is serialised: MLX models are not safe to drive from two tasks at once.
public final class MLXSwiftBackend: EngineBackend, @unchecked Sendable {
    public let runtime: EngineRuntime = .mlxSwift
    private let host = MLXModelHost()
    private let gate = SerialGate()

    public init() {}

    public func engineFeatures() async -> [String: EngineFeatures] { MLXEngines.features }
    public func availability() async -> BackendAvailability { .ready }

    public func load(_ context: ModelLoadContext) async throws { try await gate.run { try await host.load(context) } }
    public func unload(modelID: String) async { await gate.run { host.unload(modelID) } }
    public func loadedModelIDs() async -> [String] { host.loadedIDs }

    public func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer {
        try await gate.run { try await host.synthesize(job, progress: progress) }
    }

    public func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript {
        try await gate.run { try await host.transcribe(job, progress: progress) }
    }

    public func convertVoice(_ job: VoiceConversionJob, progress: EngineProgress?) async throws -> AudioBuffer {
        throw EngineError.unsupported("Voice conversion runs in the Python helper.")
    }

    /// MLX's own allocator figures, for diagnostics and the memory governor.
    public func memory() async -> MLXMemoryReport {
        MLXMemoryReport(active: Memory.activeMemory, cache: Memory.cacheMemory, peak: Memory.peakMemory)
    }
    /// Starts a fresh peak-memory measurement.
    public func resetPeakMemory() async { Memory.peakMemory = 0 }
}

public struct MLXMemoryReport: Sendable, CustomStringConvertible {
    /// Bytes held by live MLX arrays (weights, caches).
    public var active: Int
    /// Bytes MLX keeps in its buffer cache for reuse.
    public var cache: Int
    /// Highest `active` since the last reset.
    public var peak: Int

    public var description: String {
        func gb(_ b: Int) -> String { String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        return "active \(gb(active)), cache \(gb(cache)), peak \(gb(peak))"
    }
}

/// Runs one operation at a time, in arrival order. (An actor alone isn't enough: it would interleave
/// two generations at their suspension points.)
private actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
        return try await body()
    }
}

/// Loaded models. Only touched inside `SerialGate.run`, except the lock-protected id list.
private final class MLXModelHost: @unchecked Sendable {
    private enum Engine {
        case speech(MLXSpeechEngine)
        case transcription(MLXTranscriptionEngine)
    }

    private struct Loaded {
        var manifest: ModelManifest
        var variant: ModelVariant
        var engine: Engine
        var staged: [String]
    }

    private var models: [String: Loaded] = [:]
    /// Flat directories Encore staged for mlx-audio, refcounted across loaded models.
    private var staged: [String: (url: URL, created: Bool, count: Int)] = [:]
    private var sweptStaging = false

    private let idsLock = NSLock()
    private var ids: [String] = []
    var loadedIDs: [String] { idsLock.withLock { ids } }
    private func publishIDs() { let now = Array(models.keys).sorted(); idsLock.withLock { ids = now } }

    func load(_ context: ModelLoadContext) async throws {
        let id = context.manifest.id
        if let current = models[id], current.variant.id == context.variant.id { return }
        unload(id)
        if !sweptStaging { MLXRepoStaging.sweep(); sweptStaging = true }

        // Stage the primary repo and every companion before the loader runs (see MLXRepoStaging).
        var usedRepos: [String] = []
        var directories: [String: URL] = [:]
        do {
            for repo in context.variant.allRepos {
                guard let snapshot = context.repoDirectories[repo] else {
                    throw EngineError.failed("\(repo) isn't downloaded.")
                }
                directories[repo] = try retainStaged(repo: repo, snapshot: snapshot)
                usedRepos.append(repo)
            }
        } catch {
            usedRepos.forEach(releaseStaged)
            throw error
        }
        let staged = directories
        let directory: RepoDirectory = { repo in
            guard let url = staged[repo] else {
                throw EngineError.failed("\(repo) must be listed in the manifest's companionRepos for \(id).")
            }
            return url
        }
        do {
            let engine: Engine
            if context.manifest.tasks.contains(.stt) {
                engine = .transcription(try await MLXEngines.loadTranscription(context, directory: directory))
            } else {
                engine = .speech(try await MLXEngines.loadSpeech(context, directory: directory))
            }
            models[id] = Loaded(manifest: context.manifest, variant: context.variant, engine: engine, staged: usedRepos)
            publishIDs()
        } catch {
            usedRepos.forEach(releaseStaged)
            Memory.clearCache()
            throw error
        }
    }

    func unload(_ id: String) {
        guard let repos = models[id]?.staged else { return }
        // Drop the last reference to the model first, then hand its buffers back to the system.
        models[id] = nil
        publishIDs()
        repos.forEach(releaseStaged)
        Memory.clearCache()
    }

    func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer {
        guard let loaded = models[job.modelID], case .speech(let engine) = loaded.engine else {
            throw EngineError.modelNotLoaded(job.modelID)
        }
        try Task.checkCancellation()
        progress?(0)
        let parameters = ResolvedParameters(manifest: loaded.manifest, job: job.parameters)
        var reference: MaterializedArray?
        if let url = job.voice?.referenceAudio {
            reference = try loadAudioArray(from: url, sampleRate: engine.sampleRate).1
        }
        if let seed = parameters.seed { MLXRandom.seed(seed) }
        defer { Memory.clearCache() }
        let audio = try await engine.synthesize(job, reference: reference, parameters: parameters)
        try Task.checkCancellation()
        var samples = audio.asArray(Float.self)
        if audio.ndim == 2, audio.dim(0) == 2 {  // channels-first stereo → mono
            let n = audio.dim(1)
            samples = (0..<n).map { (samples[$0] + samples[n + $0]) / 2 }
        }
        progress?(1)
        return AudioBuffer(samples: samples, sampleRate: Double(engine.sampleRate))
    }

    func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript {
        guard let loaded = models[job.modelID], case .transcription(let engine) = loaded.engine else {
            throw EngineError.modelNotLoaded(job.modelID)
        }
        if job.timestamps == .word {
            throw EngineError.unsupported("Word timestamps aren't available from the MLX Swift \(loaded.manifest.engine) port.")
        }
        try Task.checkCancellation()
        progress?(0)
        let parameters = ResolvedParameters(manifest: loaded.manifest, job: job.parameters)
        let audio = try loadAudioArray(from: job.audio, sampleRate: engine.sampleRate).1
        defer { Memory.clearCache() }
        var transcript = try engine.transcribe(audio, job: job, parameters: parameters)
        try Task.checkCancellation()
        if job.timestamps == .none { transcript.segments = [] }
        if transcript.language == nil { transcript.language = job.language ?? Self.guessLanguage(transcript.text) }
        progress?(1)
        return transcript
    }

    /// The engines here don't report what language they heard; name it from the text (ISO 639-1, e.g. "en", "zh").
    static func guessLanguage(_ text: String) -> String? {
        guard text.count >= 8 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence > 0.5 else { return nil }
        return language.rawValue.split(separator: "-").first.map(String.init)
    }

    private func retainStaged(repo: String, snapshot: URL) throws -> URL {
        if var entry = staged[repo] {
            entry.count += 1
            staged[repo] = entry
            return entry.url
        }
        let result = try MLXRepoStaging.stage(repo: repo, snapshot: snapshot)
        staged[repo] = (result.url, result.created, 1)
        return result.url
    }

    private func releaseStaged(_ repo: String) {
        guard var entry = staged[repo] else { return }
        entry.count -= 1
        if entry.count > 0 { staged[repo] = entry; return }
        staged[repo] = nil
        if entry.created { MLXRepoStaging.remove(entry.url) }
    }
}
