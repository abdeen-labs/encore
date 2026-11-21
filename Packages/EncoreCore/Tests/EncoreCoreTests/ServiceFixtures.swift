import Foundation
@testable import EncoreCore

/// A deterministic engine: speech is a tone whose length depends only on the text (0.2 s + 10 ms per character),
/// transcripts are canned, conversion returns a tone as long as its input. Records every call.
final class FakeBackend: EngineBackend, @unchecked Sendable {
    let runtime: EngineRuntime
    private let lock = NSLock()
    private var _features: [String: EngineFeatures]
    private var _availability: BackendAvailability = .ready
    var synthCalls: [SynthesisJob] { lock.withLock { _synth } }
    private var _synth: [SynthesisJob] = []
    private var _transcribe: [TranscriptionJob] = []
    private var _convert: [VoiceConversionJob] = []
    private var _loads: [String] = []
    private var _unloads: [String] = []
    private var _loaded: Set<String> = []
    /// Per-call delay, to make cancellation observable.
    var delay: Duration = .zero
    var sampleRate: Double = 24_000
    /// Throw `.unsupported` for transcription jobs without a language (like the MLX Whisper port for some models).
    var unsupportedWithoutLanguage = false
    /// Called with the 1-based count of synthesis calls as each one starts.
    var onSynthesize: (@Sendable (Int) -> Void)?

    init(_ runtime: EngineRuntime, features: [String: EngineFeatures]) {
        self.runtime = runtime
        _features = features
    }

    var transcribeCalls: [TranscriptionJob] { lock.withLock { _transcribe } }
    var convertCalls: [VoiceConversionJob] { lock.withLock { _convert } }
    var loads: [String] { lock.withLock { _loads } }
    var unloads: [String] { lock.withLock { _unloads } }
    func setAvailability(_ a: BackendAvailability) { lock.withLock { _availability = a } }

    static func seconds(for text: String) -> Double { 0.2 + 0.01 * Double(text.count) }

    func engineFeatures() async -> [String: EngineFeatures] { lock.withLock { _features } }
    func availability() async -> BackendAvailability { lock.withLock { _availability } }
    func load(_ context: ModelLoadContext) async throws {
        lock.withLock { _loads.append(context.manifest.id); _loaded.insert(context.manifest.id) }
    }
    func unload(modelID: String) async { lock.withLock { _unloads.append(modelID); _loaded.remove(modelID) } }
    func loadedModelIDs() async -> [String] { lock.withLock { Array(_loaded) } }

    func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer {
        let n = lock.withLock { _synth.append(job); return _synth.count }
        onSynthesize?(n)
        guard lock.withLock({ _loaded.contains(job.modelID) }) else { throw EngineError.modelNotLoaded(job.modelID) }
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        progress?(1)
        return Self.tone(seconds: Self.seconds(for: job.text), rate: sampleRate)
    }

    func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript {
        lock.withLock { _transcribe.append(job) }
        if unsupportedWithoutLanguage, job.language == nil { throw EngineError.unsupported("Needs a language.") }
        if delay > .zero { try await Task.sleep(for: delay) }
        let audio = try await AudioReader.read(job.audio)
        return Transcript(text: "Fake transcript.", language: "en", duration: audio.duration,
                          segments: [.init(id: 0, start: 0, end: audio.duration, text: "Fake transcript.",
                                           words: job.timestamps == .word ? [.init(start: 0, end: 0.5, text: "Fake")] : nil)])
    }

    func convertVoice(_ job: VoiceConversionJob, progress: EngineProgress?) async throws -> AudioBuffer {
        lock.withLock { _convert.append(job) }
        let source = try await AudioReader.read(job.source)
        return Self.tone(seconds: source.duration, rate: sampleRate)
    }

    static func tone(seconds: Double, rate: Double) -> AudioBuffer {
        let n = Int((seconds * rate).rounded())
        return AudioBuffer(samples: (0..<n).map { Float(0.3 * sin(2 * .pi * 220 * Double($0) / rate)) }, sampleRate: rate)
    }
}

struct FixedMemory: SystemMemoryProbe {
    var memory: SystemMemory
    func read() -> SystemMemory { memory }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { t } }
    func advance(minutes: Double) { lock.withLock { t = t.addingTimeInterval(minutes * 60) } }
}

let GB: Int64 = 1_000_000_000

/// Builds a manifest from the fields tests care about.
func testManifest(_ id: String, engine: String? = nil, tasks: [String] = ["tts"], capabilities: [String: Bool] = [:],
                  presets: [String] = [], maxChunk: Int = 200, memory: Int64 = 1 * GB, sampleRate: Int = 24_000,
                  reference: [String: Any]? = nil, parameters: [[String: Any]] = []) -> ModelManifest {
    var json: [String: Any] = [
        "id": id, "name": id.capitalized, "family": "Test", "summary": "", "tasks": tasks, "engine": engine ?? id,
        "variants": [["id": "v1", "label": "V1", "repo": "test/\(id)", "downloadBytes": 1, "memoryBytes": memory, "recommended": true]],
        "license": ["name": "MIT"], "capabilities": capabilities, "languages": [],
        "presetVoices": presets.map { ["id": $0, "name": $0.capitalized] }, "expressiveTags": [],
        "parameters": parameters, "maxChunkCharacters": maxChunk, "sampleRate": sampleRate,
    ]
    if let reference { json["reference"] = reference }
    let data = try! JSONSerialization.data(withJSONObject: json)
    return try! JSONDecoder().decode(ModelManifest.self, from: data)
}

/// A temporary world: hub cache, history, voice library, pronunciations, settings, and a service over fake backends.
@MainActor
final class ServiceWorld {
    let dir: TempDir
    let hubRoot: URL
    let history: HistoryDatabase
    let voices: VoiceLibrary
    let pronunciations: PronunciationStore
    let settings: AppSettings
    let settingsKey: String
    let scratch: URL
    let clock = TestClock()
    var catalog: ModelCatalog
    var backends: [FakeBackend]
    private(set) var service: EncoreService!

    init(models: [ModelManifest], backends: [FakeBackend], downloaded: Set<String>? = nil,
         memory: SystemMemory = SystemMemory(physicalBytes: 64 * GB, availableBytes: 48 * GB)) throws {
        dir = try TempDir()
        hubRoot = dir.url.appendingPathComponent("hub")
        history = try HistoryDatabase(directory: dir.url.appendingPathComponent("History"))
        voices = VoiceLibrary(directory: dir.url.appendingPathComponent("Voices"), deletesToTrash: false)
        pronunciations = PronunciationStore(directory: dir.url)
        settingsKey = "settings-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: "EncoreServiceTests")!, key: settingsKey)
        scratch = dir.url.appendingPathComponent("Scratch")
        catalog = ModelCatalog(models: models)
        self.backends = backends
        for m in models where downloaded?.contains(m.id) ?? true {
            for v in m.variants { try Self.fakeSnapshot(v.repo, root: hubRoot) }
        }
        let settings = self.settings, clock = self.clock
        let runtime = ModelRuntime(memory: FixedMemory(memory: memory), idleMinutes: { settings.snapshot().idleUnloadMinutes },
                                   now: { clock.now }, autoSweep: false)
        service = EncoreService(catalog: catalog, history: history, voices: voices, pronunciations: pronunciations,
                                settings: settings, hub: HubLocalStore(layout: HubCacheLayout(root: hubRoot)),
                                backends: backends, runtime: runtime, scratchDirectory: scratch)
    }

    deinit { UserDefaults(suiteName: "EncoreServiceTests")?.removeObject(forKey: settingsKey) }

    static func fakeSnapshot(_ repo: String, root: URL) throws {
        let layout = HubCacheLayout(root: root)
        let sha = String(repeating: "a", count: 40)
        let snap = layout.snapshotDirectory(repo, commit: sha)
        try FileManager.default.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snap.appendingPathComponent("config.json"))
        try FileManager.default.createDirectory(at: layout.refFile(repo, ref: "main").deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(sha.utf8).write(to: layout.refFile(repo, ref: "main"))
    }

    /// Writes a WAV and returns its URL.
    func wav(_ name: String, _ samples: [Float], rate: Double = 24_000) throws -> URL {
        let url = dir.url.appendingPathComponent(name)
        try AudioExporter.writeWAV(AudioBuffer(samples: samples, sampleRate: rate), to: url, encoding: .float32)
        return url
    }

    func addVoice(_ name: String, seconds: Double = 6, transcript: String = "This is my reference voice.") async throws -> Voice {
        let clip = try wav("\(name)-ref.wav", Signal.speechLike(seconds: seconds, rate: 24_000))
        return try await voices.add(Voice(name: name, origin: .cloned, transcript: transcript, duration: seconds), referenceAudio: clip)
    }

    /// Files left in the scratch folder (design candidates excluded) and the history audio folder.
    func leftovers(includeHistory: Bool = true) -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        for root in includeHistory ? [scratch, history.audioDirectory] : [scratch] {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(u.path)
            }
        }
        return out
    }
}

/// Drains a stream, returning the events.
func collect<E>(_ stream: AsyncThrowingStream<E, Error>) async throws -> [E] {
    var out: [E] = []
    for try await e in stream { out.append(e) }
    return out
}

func finishedRecord(_ events: [GenerationEvent]) -> GenerationRecord? {
    for e in events { if case .finished(let r) = e { return r } }
    return nil
}

func stages(_ events: [GenerationEvent]) -> [String] {
    events.compactMap { if case .stage(let s) = $0 { s } else { nil } }
}
