import Foundation

/// Encore's local HTTP API: what `LocalHTTPServer` serves while the app is open and the API is turned on.
///
///     GET  /health                      {"status": "ok", "version": …}
///     GET  /v1/models                   every model in the catalog, OpenAI list shape, plus what each can do
///     GET  /v1/voices                   the voice library
///     POST /v1/audio/speech             OpenAI-compatible text to speech; returns audio
///     POST /v1/audio/transcriptions     OpenAI-compatible transcription (multipart upload)
///     POST /v1/speech                   a `SpeechRequest`; streams events as NDJSON
///     POST /v1/transcriptions           a `TranscriptionRequest` (a file path); NDJSON
///     POST /v1/voice-changes            a `VoiceConversionRequest`; NDJSON
///     POST /v1/conversations            a `ConversationRequest`; NDJSON
///     POST /mcp                         the MCP server (streamable HTTP)
///
/// Only requests addressed to this Mac by name (Host: 127.0.0.1, localhost or [::1]) and not sent by a web page from
/// another site (Origin) are served, which keeps web pages from reaching it through DNS rebinding or form posts.
public final class LocalAPI: Sendable {
    public let resolver: APIResolver
    public let version: String
    let mcp: MCPServer

    /// - Parameter play: plays a finished take on this Mac (the MCP tools' `play` option). Nil turns playing off.
    public init(service: EncoreService, version: String, play: (@Sendable (URL, String) async -> Void)? = nil) {
        resolver = APIResolver(service: service)
        self.version = version
        mcp = MCPServer(resolver: resolver, version: version, play: play)
    }

    var service: EncoreService { resolver.service }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard Self.isFromThisMac(request) else {
            return Self.error(APIError(403, "forbidden", "Encore's local API only answers apps on this Mac, not web pages."))
        }
        do {
            switch (request.method, request.path) {
            case ("GET", "/"), ("GET", "/health"), ("GET", "/v1/health"):
                return .json(["status": "ok", "name": "Encore", "version": version])
            case ("GET", "/v1/models"):
                return .json(["object": "list", "data": resolver.modelListing()])
            case ("GET", "/v1/voices"):
                return .json(["object": "list", "data": await resolver.voiceListing()])
            case ("POST", "/v1/audio/speech"):
                return try await openAISpeech(request)
            case ("POST", "/v1/audio/transcriptions"):
                return try await openAITranscription(request)
            case ("POST", "/v1/speech"):
                var r = try Self.decode(SpeechRequest.self, request)
                r.voice = await resolver.libraryAware(r.voice, for: r.modelID)
                return await Self.ndjson(service.speak(r))
            case ("POST", "/v1/transcriptions"):
                return await Self.ndjson(service.transcribe(try Self.decode(TranscriptionRequest.self, request)))
            case ("POST", "/v1/voice-changes"):
                var r = try Self.decode(VoiceConversionRequest.self, request)
                r.voice = await resolver.libraryAware(r.voice, for: r.modelID)
                return await Self.ndjson(service.convertVoice(r))
            case ("POST", "/v1/conversations"):
                var r = try Self.decode(ConversationRequest.self, request)
                for i in r.script.speakers.indices {
                    r.script.speakers[i].voice = await resolver.libraryAware(r.script.speakers[i].voice, for: r.modelID)
                }
                return await Self.ndjson(service.renderConversation(r))
            case (_, "/mcp"):
                return await mcp.handle(request)
            case (_, let path) where Self.routes.contains(path):
                return Self.error(APIError(405, "method_not_allowed", "\(request.method) isn't allowed on \(path)."))
            default:
                return Self.error(APIError(404, "not_found", "There's nothing at \(request.path). See GET /v1/models, POST /v1/audio/speech or /mcp."))
            }
        } catch {
            return Self.error(APIError.from(error))
        }
    }

    static let routes: Set<String> = ["/", "/health", "/v1/health", "/v1/models", "/v1/voices", "/v1/audio/speech",
                                      "/v1/audio/transcriptions", "/v1/speech", "/v1/transcriptions", "/v1/voice-changes",
                                      "/v1/conversations"]

    // MARK: - Who may call

    static func isFromThisMac(_ request: HTTPRequest) -> Bool {
        guard let host = request.header("host").flatMap(hostName), loopbackNames.contains(host) else { return false }
        if let origin = request.header("origin") {
            guard let url = URL(string: origin), let h = url.host?.lowercased(), loopbackNames.contains(h) || loopbackNames.contains("[\(h)]") else {
                return false
            }
        }
        return true
    }

    static let loopbackNames: Set<String> = ["127.0.0.1", "localhost", "[::1]", "::1"]

    /// "localhost:7171" → "localhost"; "[::1]:7171" → "[::1]".
    static func hostName(_ header: String) -> String? {
        let h = header.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("[") { return h.firstIndex(of: "]").map { String(h[...$0]) } }
        return h.split(separator: ":", maxSplits: 1).first.map(String.init)
    }

    // MARK: - OpenAI-compatible speech

    /// `{"model", "input", "voice", "response_format", "speed", "instructions"}`, plus Encore's own `language`,
    /// `parameters` and `save_to_history` (default true: the take appears in History like any other).
    func openAISpeech(_ request: HTTPRequest) async throws -> HTTPResponse {
        let body = try Self.object(request)
        guard let input = body["input"] as? String, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(400, "invalid_request", "input is required: the text to speak.")
        }
        let format = try Self.audioFormat(body["response_format"] as? String)
        let choice = await resolver.voice(body["voice"] as? String)
        let model = try resolver.speechModel(named: body["model"] as? String, for: [choice])
        var r = SpeechRequest(modelID: model.id, text: input)
        r.voice = try resolver.selection(choice, for: model)
        if model.capabilities.styleInstruction, let s = body["instructions"] as? String, !s.isEmpty { r.instruct = s }
        r.language = body["language"] as? String
        r.parameters = try APIResolver.parameters(body["parameters"], for: model)
        if let speed = APIResolver.number(body["speed"]), model.parameters.contains(where: { $0.key == "speed" }) {
            r.parameters["speed"] = .double(speed)
        }
        r.post = service.settings.snapshot().postProcessing
        r.saveToHistory = body["save_to_history"] as? Bool ?? true
        r.title = body["title"] as? String
        let record = try await APIResolver.finish(service.speak(r))
        defer { if !r.saveToHistory { try? FileManager.default.removeItem(at: record.audioURL) } }
        let data = try await Self.encode(record, as: format)
        var headers = ["X-Encore-Model": model.id, "X-Encore-Duration": String(format: "%.3f", record.duration),
                       "X-Sample-Rate": String(Int(record.sampleRate))]
        if r.saveToHistory { headers["X-Encore-Take"] = record.id.uuidString }
        return .data(data, type: format.contentType, headers: headers)
    }

    enum SpeechFormat: String { case wav, mp3, m4a, pcm
        var contentType: String {
            switch self {
            case .wav: "audio/wav"
            case .mp3: "audio/mpeg"
            case .m4a: "audio/mp4"
            case .pcm: "audio/pcm"
            }
        }
    }

    /// OpenAI's default is MP3; without ffmpeg an unspecified format comes back as WAV instead.
    static func audioFormat(_ name: String?) throws -> SpeechFormat {
        switch name?.lowercased() {
        case nil, "": return FFmpeg.isAvailable ? .mp3 : .wav
        case "wav": return .wav
        case "pcm": return .pcm
        case "aac", "m4a": return .m4a
        case "mp3":
            guard FFmpeg.isAvailable else {
                throw APIError(400, "ffmpeg_missing", "MP3 needs ffmpeg, which Encore can't find (brew install ffmpeg). Ask for wav or aac instead.")
            }
            return .mp3
        case let other?:
            throw APIError(400, "unsupported_format", "Encore can return wav, mp3, aac or pcm, not \(other).")
        }
    }

    static func encode(_ record: GenerationRecord, as format: SpeechFormat) async throws -> Data {
        let buffer = try await AudioReader.read(record.audioURL)
        if format == .pcm {
            // 16-bit little-endian mono at the take's sample rate (X-Sample-Rate).
            var data = Data(capacity: buffer.samples.count * 2)
            for s in buffer.samples {
                let v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
                withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
            }
            return data
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("encore-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("speech.\(format == .m4a ? "m4a" : format.rawValue)")
        let fileFormat: AudioFileFormat = switch format { case .mp3: .mp3; case .m4a: .m4a; default: .wav }
        try await AudioExporter.export(buffer, to: file, format: fileFormat, options: AudioExportOptions(wavEncoding: .pcm16))
        return try Data(contentsOf: file)
    }

    // MARK: - OpenAI-compatible transcription

    /// multipart/form-data with `file`, and optionally `model`, `language`, `response_format` (json, text, srt, vtt,
    /// verbose_json), `temperature` and `timestamp_granularities[]` (segment, word).
    func openAITranscription(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.contentType == "multipart/form-data", let header = request.header("content-type") else {
            throw APIError(415, "invalid_request", "Send the file as multipart/form-data, or POST a file path to /v1/transcriptions.")
        }
        let form = try MultipartForm.parse(request.body, contentType: header)
        guard let file = form.file("file"), !file.data.isEmpty else { throw APIError(400, "invalid_request", "file is required.") }
        let format = (form.value("response_format") ?? "json").lowercased()
        guard ["json", "text", "srt", "vtt", "verbose_json"].contains(format) else {
            throw APIError(400, "unsupported_format", "response_format can be json, text, srt, vtt or verbose_json.")
        }
        let model = try resolver.transcriptionModel(named: form.value("model"))

        // Uploads stay in the service's scratch folder (swept after a day), so History's transcript can still play it today.
        let name = Self.safeFileName(file.filename ?? "audio")
        let dir = service.scratchDirectory.appendingPathComponent("Uploads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try file.data.write(to: url)

        var r = TranscriptionRequest(modelID: model.id, mediaPath: url.path)
        if let l = form.value("language")?.trimmingCharacters(in: .whitespaces), !l.isEmpty { r.language = l }
        let granularities = Set(form.values("timestamp_granularities[]") + form.values("timestamp_granularities"))
        r.timestamps = granularities.contains("word") ? .word : .segment
        if let t = form.value("temperature").flatMap(Double.init), model.parameters.contains(where: { $0.key == "temperature" }) {
            r.parameters["temperature"] = .double(t)
        }
        let record = try await APIResolver.finish(service.transcribe(r))
        let t = record.transcript
        let formatter = TranscriptFormatter()
        switch format {
        case "text": return .text(formatter.plainText(t))
        case "srt": return .text(formatter.srt(t), type: "application/x-subrip; charset=utf-8")
        case "vtt": return .text(formatter.vtt(t), type: "text/vtt; charset=utf-8")
        case "verbose_json":
            var out: [String: Any] = ["task": "transcribe", "text": t.text, "language": t.language ?? "",
                                      "duration": t.duration ?? 0,
                                      "segments": t.segments.map { ["id": $0.id, "start": $0.start, "end": $0.end, "text": $0.text] }]
            if r.timestamps == .word {
                out["words"] = t.segments.flatMap { $0.words ?? [] }.map { ["word": $0.text, "start": $0.start, "end": $0.end] }
            }
            return .json(out)
        default:
            return .json(["text": t.text])
        }
    }

    static func safeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return base.isEmpty || base.hasPrefix(".") ? "audio" + base : base
    }

    // MARK: - Native endpoints

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static func decode<T: Decodable>(_ type: T.Type, _ request: HTTPRequest) throws -> T {
        guard !request.body.isEmpty else { throw APIError(400, "invalid_request", "The request needs a JSON body.") }
        return try JSONDecoder().decode(T.self, from: request.body)
    }

    static func object(_ request: HTTPRequest) throws -> [String: Any] {
        guard let any = try? JSONSerialization.jsonObject(with: request.body), let dict = any as? [String: Any] else {
            throw APIError(400, "invalid_request", "The request body must be a JSON object.")
        }
        return dict
    }

    /// Streams a service request's events as NDJSON, one event per line. Problems found before the first event (an
    /// unknown model, a missing download) come back as an ordinary error response; later ones as an `error` line.
    static func ndjson<E: Encodable & Sendable>(_ events: AsyncThrowingStream<E, Error>) async -> HTTPResponse {
        let iterator = IteratorBox(events.makeAsyncIterator())
        let first: E?
        do { first = try await iterator.next() } catch { return Self.error(APIError.from(error)) }
        let (out, continuation) = AsyncStream<Data>.makeStream()
        let task = Task {
            func line(_ e: E) -> Data { ((try? encoder.encode(e)) ?? Data("{}".utf8)) + Data("\n".utf8) }
            if let first { continuation.yield(line(first)) }
            do {
                while let e = try await iterator.next() { continuation.yield(line(e)) }
            } catch {
                let e = APIError.from(error)
                let data = (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": ["code": e.code, "message": e.message]],
                                                        options: [.sortedKeys])) ?? Data()
                continuation.yield(data + Data("\n".utf8))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/x-ndjson"], body: .stream(out))
    }

    static func error(_ e: APIError) -> HTTPResponse {
        .json(e.json, status: e.status, headers: e.status == 405 ? ["Allow": "GET, POST"] : [:])
    }
}

/// Lets one consumer at a time pull from a stream across tasks.
final class IteratorBox<E: Sendable>: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<E, Error>.AsyncIterator
    init(_ iterator: AsyncThrowingStream<E, Error>.AsyncIterator) { self.iterator = iterator }
    func next() async throws -> E? { try await iterator.next() }
}
