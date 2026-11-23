import Foundation

/// An error the local API returns as `{"error": {"message", "type", "code"}}` with an HTTP status.
public struct APIError: Error, LocalizedError, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public init(_ status: Int, _ code: String, _ message: String) { self.status = status; self.code = code; self.message = message }
    public var errorDescription: String? { message }

    /// Any error, as the API reports it.
    public static func from(_ error: Error) -> APIError {
        switch error {
        case let e as APIError: return e
        case let e as ServiceError: return APIError(status(for: e), e.code, e.localizedDescription)
        case let e as DecodingError: return APIError(400, "invalid_request", "The request body doesn't fit: \(describe(e))")
        case is CancellationError: return APIError(499, "canceled", "The request was canceled.")
        case let e as MultipartForm.Failure: return APIError(400, "invalid_request", e.message)
        default: return APIError(500, "internal_error", error.localizedDescription)
        }
    }

    static func status(for e: ServiceError) -> Int {
        switch e {
        case .unknownModel, .voiceMissing, .unknownPresetVoice, .unknownVoiceTags: 404
        case .modelNotDownloaded, .backendNeedsSetup, .backendUnavailable, .noTranscriptionModel: 409
        case .generationFailed: 500
        default: 400
        }
    }

    static func describe(_ e: DecodingError) -> String {
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "" : " (at \(p))"
        }
        switch e {
        case .keyNotFound(let key, let c): return "“\(key.stringValue)” is required\(path(c))."
        case .typeMismatch(_, let c), .valueNotFound(_, let c): return c.debugDescription + path(c)
        case .dataCorrupted(let c): return c.debugDescription + path(c)
        @unknown default: return e.localizedDescription
        }
    }

    var json: [String: Any] {
        ["error": ["message": message, "type": status >= 500 ? "server_error" : "invalid_request_error", "code": code]]
    }
}

/// Turns the loose names API clients send ("Mira", "tts-1", "alloy", nothing at all) into models and voices.
public struct APIResolver: Sendable {
    public let service: EncoreService

    public init(service: EncoreService) { self.service = service }

    /// Model names OpenAI clients send; they mean "Encore's default model for this".
    static let openAIModels: Set<String> = ["tts-1", "tts-1-hd", "gpt-4o-mini-tts", "gpt-4o-tts",
                                            "whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    /// Voice names OpenAI clients send; when the model has no voice by that name they mean its default voice.
    static let openAIVoices: Set<String> = ["alloy", "ash", "ballad", "coral", "echo", "fable", "nova", "onyx", "sage",
                                            "shimmer", "verse", "marin", "cedar"]

    // MARK: Models

    /// The model a name means, by id or display name; nil when the name is empty or an OpenAI model name.
    func model(named name: String?, task: ModelTask) throws -> ModelManifest? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              !Self.openAIModels.contains(name.lowercased()) else { return nil }
        let catalog = service.catalog
        guard let m = catalog.model(name) ?? catalog.models.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? catalog.model(name.lowercased()) else {
            throw APIError(404, "unknown_model", "There's no model called “\(name)”. GET /v1/models lists them.")
        }
        guard m.tasks.contains(task) else { throw ServiceError.wrongTask(modelID: m.id, modelName: m.name, task: task) }
        return m
    }

    /// The speech model to use: the one named, else the one last used in Encore, else the first downloaded one that can
    /// say this voice.
    func speechModel(named name: String?, for voices: [VoiceChoice]) throws -> ModelManifest {
        if let m = try model(named: name, task: .tts) { return m }
        let clones = voices.contains { if case .library = $0 { true } else { false } }
        var pool = service.catalog.models(for: .tts).filter { service.isDownloaded($0) }
        if clones { pool = pool.filter(\.capabilities.cloning) }
        let presets = voices.compactMap { if case .named(let n) = $0 { n } else { nil } }
        if !presets.isEmpty {
            let fitting = pool.filter { m in presets.allSatisfy { Self.preset($0, in: m) != nil } }
            if !fitting.isEmpty { pool = fitting }
        }
        let last = service.settings.snapshot().lastUsedModels[clones ? .cloning : .speech]
        if let m = pool.first(where: { $0.id == last }) ?? pool.first { return m }
        throw APIError(409, "no_speech_model", clones
            ? "None of your downloaded speech models can use library voices. Download one that clones (Chatterbox Turbo, Qwen3-TTS, VoxCPM2…) in Encore's Models screen."
            : "No speech model is downloaded yet. Download one in Encore's Models screen.")
    }

    func transcriptionModel(named name: String?) throws -> ModelManifest {
        try model(named: name, task: .stt) ?? service.defaultTranscriptionModel()
    }

    func voiceChangeModel(named name: String?) throws -> ModelManifest {
        if let m = try model(named: name, task: .voiceConversion) { return m }
        guard let m = service.catalog.models(for: .voiceConversion).first(where: { service.isDownloaded($0) }) else {
            throw APIError(409, "no_voice_change_model", "The voice changer model isn't downloaded yet. Download it in Encore's Models screen.")
        }
        return m
    }

    // MARK: Voices

    /// What a voice name points at before the model is known.
    enum VoiceChoice: Sendable {
        case automatic
        case library(Voice)
        /// A built-in voice of some model, or an OpenAI voice name.
        case named(String)
    }

    /// "Mira", a library voice's id, "automatic", or a model's built-in voice.
    func voice(_ text: String?) async -> VoiceChoice {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !["automatic", "default"].contains(text.lowercased()) else { return .automatic }
        let library = await libraryVoices()
        if let id = UUID(uuidString: text), let v = library.first(where: { $0.id == id }) { return .library(v) }
        if let v = library.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return .library(v) }
        return .named(text)
    }

    /// The selection for this model, or an error listing the voices it does have.
    func selection(_ choice: VoiceChoice, for m: ModelManifest) throws -> VoiceSelection {
        switch choice {
        case .automatic: return .automatic
        case .library(let v):
            guard m.capabilities.cloning else {
                throw APIError(400, "voice_not_supported",
                               "\(m.name) can't use library voices like “\(v.name)”. Pick a model that clones, or one of its own voices.")
            }
            return .library(v.id)
        case .named(let name):
            if let id = Self.preset(name, in: m) { return .preset(id) }
            if Self.openAIVoices.contains(name.lowercased()) { return .automatic }
            let own = m.presetVoices.map(\.name)
            throw APIError(404, "unknown_voice", "There's no voice called “\(name)” in your library"
                           + (own.isEmpty ? " (and \(m.name) has no built-in voices)." : " or in \(m.name) (\(own.joined(separator: ", "))).")
                           + " GET /v1/voices lists your library.")
        }
    }

    /// A built-in voice's id, matched by id or name.
    static func preset(_ name: String, in m: ModelManifest) -> String? {
        m.presetVoices.first { $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
    }

    /// Native requests decode a voice name as a preset; this turns names of library voices into library selections.
    func libraryAware(_ selection: VoiceSelection, for modelID: String) async -> VoiceSelection {
        guard case .preset(let name) = selection else { return selection }
        if let m = service.catalog.model(modelID), Self.preset(name, in: m) != nil { return selection }
        if case .library(let v) = await voice(name) { return .library(v.id) }
        return selection
    }

    func libraryVoices() async -> [Voice] {
        let library = service.voices
        return await MainActor.run { library.voices }
    }

    // MARK: Listings

    func voiceListing() async -> [[String: Any]] {
        await libraryVoices().map { v in
            var item: [String: Any] = ["id": v.id.uuidString, "name": v.name, "kind": v.origin.rawValue, "tags": v.tags,
                                       "duration": (v.duration * 10).rounded() / 10]
            if let l = v.language { item["language"] = l }
            if !v.notes.isEmpty { item["notes"] = v.notes }
            return item
        }
    }

    func modelListing() -> [[String: Any]] {
        service.catalog.models.map { m in
            var tasks: [String] = []
            if m.tasks.contains(.tts) { tasks.append("speech") }
            if m.tasks.contains(.stt) { tasks.append("transcription") }
            if m.tasks.contains(.voiceConversion) { tasks.append("voice_change") }
            var item: [String: Any] = [
                "id": m.id, "object": "model", "owned_by": m.author ?? m.family, "created": 0,
                "name": m.name, "summary": m.summary, "tasks": tasks, "downloaded": service.isDownloaded(m),
                "clones_voices": m.capabilities.cloning, "license": m.license.name,
                "languages": m.languages.map(\.code),
            ]
            if !m.presetVoices.isEmpty { item["voices"] = m.presetVoices.map { ["id": $0.id, "name": $0.name] } }
            if m.capabilities.styleInstruction { item["takes_style_directions"] = true }
            if m.capabilities.wordTimestamps { item["word_timestamps"] = true }
            return item
        }
    }

    // MARK: Running

    /// Drives a generation to its record, reporting progress.
    static func finish(_ events: AsyncThrowingStream<GenerationEvent, Error>,
                       progress: (@Sendable (Double, String?) async -> Void)? = nil) async throws -> GenerationRecord {
        var record: GenerationRecord?
        for try await e in events {
            switch e {
            case .stage(let s): await progress?(-1, s)
            case .progress(let f): await progress?(f, nil)
            case .finished(let r): record = r
            }
        }
        guard let record else { throw APIError(500, "internal_error", "The generation ended without a result.") }
        return record
    }

    static func finish(_ events: AsyncThrowingStream<TranscriptionEvent, Error>,
                       progress: (@Sendable (Double, String?) async -> Void)? = nil) async throws -> TranscriptionRecord {
        var record: TranscriptionRecord?
        for try await e in events {
            switch e {
            case .stage(let s): await progress?(-1, s)
            case .progress(let f): await progress?(f, nil)
            case .finished(let r): record = r
            }
        }
        guard let record else { throw APIError(500, "internal_error", "The transcription ended without a result.") }
        return record
    }

    /// Writes a take to `path` in the format its extension names (wav, m4a, mp3).
    static func export(_ record: GenerationRecord, to path: String) async throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard (path as NSString).expandingTildeInPath.hasPrefix("/") else {
            throw APIError(400, "invalid_path", "output_path must be an absolute path.")
        }
        guard let format = AudioFileFormat(fileExtension: url.pathExtension) else {
            throw APIError(400, "invalid_path", "output_path must end in .wav, .m4a or .mp3.")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
            throw APIError(400, "invalid_path", "The folder \(url.deletingLastPathComponent().path) doesn't exist.")
        }
        if format.needsFFmpeg, !FFmpeg.isAvailable {
            throw APIError(400, "ffmpeg_missing", "MP3 needs ffmpeg (brew install ffmpeg). Use .wav or .m4a instead.")
        }
        let buffer = try await AudioReader.read(record.audioURL)
        try await AudioExporter.export(buffer, to: url, format: format, options: AudioExportOptions(wavEncoding: .pcm16))
        return url
    }

    /// An absolute, existing file a request names.
    static func existingFile(_ path: String?, field: String) throws -> URL {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            throw APIError(400, "invalid_request", "\(field) is required.")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw APIError(400, "invalid_path", "\(field) must be an absolute path.") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else {
            throw APIError(404, "file_not_found", "There's no file at \(expanded).")
        }
        return URL(fileURLWithPath: expanded)
    }

    /// Lenient numbers from JSON (Int, Double, numeric strings).
    static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: d
        case let i as Int: Double(i)
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    /// `{"temperature": 0.7, "seed": 3}` checked against the model's parameters.
    static func parameters(_ any: Any?, for m: ModelManifest) throws -> ParamValues {
        guard let any else { return [:] }
        guard let dict = any as? [String: Any] else { throw APIError(400, "invalid_request", "parameters must be an object.") }
        var out: ParamValues = [:]
        for (key, value) in dict {
            guard let spec = m.parameters.first(where: { $0.key == key }) else {
                let keys = m.parameters.map(\.key).joined(separator: ", ")
                throw APIError(400, "unknown_parameter", "\(m.name) has no parameter “\(key)”." + (keys.isEmpty ? "" : " It has: \(keys)."))
            }
            switch (spec.type, value) {
            case (.bool, let b as Bool): out[key] = .bool(b)
            case (.int, _), (.seed, _):
                guard let n = number(value) else { throw APIError(400, "invalid_parameter", "\(key) must be a number.") }
                out[key] = .int(Int(n))
            case (.float, _):
                guard let n = number(value) else { throw APIError(400, "invalid_parameter", "\(key) must be a number.") }
                out[key] = .double(n)
            case (_, let s as String): out[key] = .string(s)
            case (_, let b as Bool): out[key] = .bool(b)
            default:
                guard let n = number(value) else { throw APIError(400, "invalid_parameter", "\(key) has an unexpected value.") }
                out[key] = .double(n)
            }
        }
        return out
    }
}
