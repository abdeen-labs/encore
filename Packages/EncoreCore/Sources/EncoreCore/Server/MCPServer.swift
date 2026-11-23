import Foundation

/// Encore as an MCP server over streamable HTTP (`POST /mcp`), stateless: every request carries everything it needs.
///
/// Tools: speak, perform_script, transcribe, change_voice, list_voices, list_models. Making a voice (cloning needs the
/// speaker's consent; designing means choosing between auditions) stays in the app.
///
/// A `tools/call` whose `_meta` has a `progressToken`, from a client that accepts `text/event-stream`, gets its
/// progress as `notifications/progress` events before the result; otherwise the result comes back as plain JSON.
final class MCPServer: Sendable {
    let resolver: APIResolver
    let version: String
    let play: (@Sendable (URL, String) async -> Void)?

    init(resolver: APIResolver, version: String, play: (@Sendable (URL, String) async -> Void)?) {
        self.resolver = resolver; self.version = version; self.play = play
    }

    var service: EncoreService { resolver.service }

    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        Encore makes speech, transcripts and voice changes on this Mac with local models; nothing leaves the computer. \
        Call list_voices to see the user's own voices (cloned and designed in Encore) before choosing one by name. \
        Every take is also saved in Encore's History. Generation runs one job at a time and can take from seconds to minutes.
        """

    // MARK: - Transport

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.method == "POST" else {
            return .json(APIError(405, "method_not_allowed", "Encore's MCP endpoint takes POST only.").json, status: 405,
                         headers: ["Allow": "POST"])
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(Self.failure(id: NSNull(), code: -32700, message: "The body isn't JSON."), status: 400)
        }
        // A batch (older protocol versions): answer every request in it, in one array.
        if let batch = message as? [Any] {
            var replies: [Any] = []
            for item in batch {
                if let reply = await reply(to: item, progress: nil) { replies.append(reply) }
            }
            return replies.isEmpty ? .empty(202) : .json(replies)
        }
        guard let dict = message as? [String: Any] else {
            return .json(Self.failure(id: NSNull(), code: -32600, message: "Expected a JSON-RPC message."), status: 400)
        }
        // Notifications and responses need no answer.
        guard dict["method"] is String, let id = dict["id"], !(id is NSNull) else { return .empty(202) }

        let params = dict["params"] as? [String: Any]
        let token = (params?["_meta"] as? [String: Any])?["progressToken"]
        guard dict["method"] as? String == "tools/call", let token, request.accepts("text/event-stream") else {
            return .json(await reply(to: dict, progress: nil) ?? [:])
        }

        // Stream progress, then the result, as server-sent events.
        let (out, continuation) = AsyncStream<Data>.makeStream()
        let task = Task {
            @Sendable func event(_ object: Any) -> Data {
                let json = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
                return Data("event: message\ndata: ".utf8) + json + Data("\n\n".utf8)
            }
            // Progress must rise with every notification, so a stage ("Loading Soprano…") rides along with the next step.
            let stage = StageMemo()
            let reply = await self.reply(to: dict) { fraction, message in
                guard let (value, text) = stage.update(fraction, message) else { return }
                var p: [String: Any] = ["progressToken": token, "progress": value, "total": 1]
                if let text { p["message"] = text }
                continuation.yield(event(["jsonrpc": "2.0", "method": "notifications/progress", "params": p]))
            }
            if let reply { continuation.yield(event(reply)) }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return HTTPResponse(status: 200, headers: ["Content-Type": "text/event-stream"], body: .stream(out))
    }

    typealias Progress = @Sendable (Double, String?) async -> Void

    /// The JSON-RPC reply to one message, or nil for notifications.
    func reply(to message: Any, progress: Progress?) async -> [String: Any]? {
        guard let dict = message as? [String: Any], let method = dict["method"] as? String else { return nil }
        guard let id = dict["id"], !(id is NSNull) else { return nil }
        let params = dict["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
            return Self.success(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "encore", "title": "Encore", "version": self.version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return Self.success(id: id, [:])
        case "tools/list":
            return Self.success(id: id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.failure(id: id, code: -32602, message: "tools/call needs a tool name.")
            }
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                return Self.failure(id: id, code: -32602, message: "There's no tool called \(name).")
            }
            let args = params["arguments"] as? [String: Any] ?? [:]
            do {
                let text = try await call(name, args, progress: progress)
                return Self.success(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch is CancellationError {
                return Self.success(id: id, ["content": [["type": "text", "text": "Canceled."]], "isError": true])
            } catch {
                return Self.success(id: id, ["content": [["type": "text", "text": APIError.from(error).message]], "isError": true])
            }
        default:
            return Self.failure(id: id, code: -32601, message: "Encore doesn't support \(method).")
        }
    }

    static func success(id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    static func failure(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    // MARK: - Tools

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        tool("speak", title: "Speak text",
             "Turn text into speech with a local model, in one of the user's voices or a model's built-in voice. "
             + "Supports Encore's script tags: [pause 0.8s], [voice: Name] to switch voices, and sounds like [laugh] on models that have them. "
             + "Returns the path of the audio file.",
             properties: [
                "text": string("What to say."),
                "voice": string("A voice from list_voices: one of the user's voices by name, or a model's built-in voice. Leave out for the model's default."),
                "model": string("A speech model id from list_models. Leave out to use the one the user last used."),
                "language": string("Language code such as en, fr or ja, for models that need one."),
                "style": string("How to say it (\"warm and slow, a little amused\"), for models that take style directions."),
                "output_path": string("Also save a copy here: an absolute path ending in .wav, .m4a or .mp3."),
                "play": ["type": "boolean", "description": "Play it out loud on this Mac when it's ready."],
             ], required: ["text"]),
        tool("perform_script", title: "Perform a script",
             "Perform a multi-speaker script, one voice per speaker. Write one line per turn as \"Name: what they say\" "
             + "(screenplay layout also works). Returns the path of the finished recording.",
             properties: [
                "script": string("The script, with speaker names."),
                "cast": ["type": "object", "additionalProperties": ["type": "string"],
                         "description": "Speaker name to voice name, e.g. {\"Ava\": \"Mira\"}. Uncast speakers get built-in voices where the model has them."],
                "model": string("A speech model id from list_models. Leave out to use the one the user last used."),
                "language": string("Language code, for models that need one."),
                "output_path": string("Also save a copy here: an absolute path ending in .wav, .m4a or .mp3."),
                "play": ["type": "boolean", "description": "Play it out loud on this Mac when it's ready."],
             ], required: ["script"]),
        tool("transcribe", title: "Transcribe audio or video",
             "Transcribe an audio or video file on this Mac with a local model.",
             properties: [
                "path": string("Absolute path of the audio or video file."),
                "model": string("A transcription model id from list_models. Leave out for the default."),
                "language": string("Language code. Leave out to detect it."),
                "format": ["type": "string", "enum": ["text", "timestamped", "srt", "vtt", "json"],
                           "description": "How to return the transcript. Default: text."],
                "word_timestamps": ["type": "boolean", "description": "Time every word (json format), on models that can."],
             ], required: ["path"], readOnly: true),
        tool("change_voice", title: "Change the voice in a recording",
             "Re-voice a recording in one of the user's voices, keeping its words, timing and delivery. Returns the path of the new audio.",
             properties: [
                "path": string("Absolute path of the recording."),
                "voice": string("One of the user's voices, by name (see list_voices)."),
                "output_path": string("Also save a copy here: an absolute path ending in .wav, .m4a or .mp3."),
                "play": ["type": "boolean", "description": "Play it out loud on this Mac when it's ready."],
             ], required: ["path", "voice"]),
        tool("list_voices", title: "List voices",
             "The user's own voices, and the built-in voices of the speech models that are downloaded.",
             properties: ["model": string("Only this model's built-in voices.")], required: [], readOnly: true),
        tool("list_models", title: "List models",
             "Encore's speech, transcription and voice-changer models: what each is good at, and whether it's downloaded.",
             properties: [:], required: [], readOnly: true),
    ]

    static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static func tool(_ name: String, title: String, _ description: String, properties: [String: Any], required: [String],
                     readOnly: Bool = false) -> [String: Any] {
        ["name": name, "title": title, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required],
         "annotations": ["title": title, "readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false]]
    }

    func call(_ name: String, _ args: [String: Any], progress: Progress?) async throws -> String {
        switch name {
        case "speak": try await speak(args, progress: progress)
        case "perform_script": try await performScript(args, progress: progress)
        case "transcribe": try await transcribe(args, progress: progress)
        case "change_voice": try await changeVoice(args, progress: progress)
        case "list_voices": try await listVoices(args)
        case "list_models": listModels()
        default: throw APIError(400, "unknown_tool", "There's no tool called \(name).")
        }
    }

    func speak(_ args: [String: Any], progress: Progress?) async throws -> String {
        guard let text = args["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIError(400, "invalid_request", "text is required.")
        }
        let choice = await resolver.voice(args["voice"] as? String)
        let model = try resolver.speechModel(named: args["model"] as? String, for: [choice])
        var r = SpeechRequest(modelID: model.id, text: text)
        r.voice = try resolver.selection(choice, for: model)
        r.language = args["language"] as? String
        var notes: [String] = []
        if let style = args["style"] as? String, !style.isEmpty {
            if model.capabilities.styleInstruction { r.instruct = style } else { notes.append("\(model.name) doesn't take style directions, so the style was left out.") }
        }
        r.post = service.settings.snapshot().postProcessing
        let record = try await APIResolver.finish(service.speak(r), progress: progress)
        return try await finished(record, args, summary: "Spoke \(Self.seconds(record.duration)) with \(model.name)"
                                  + (record.voiceName.map { ", voice \($0)" } ?? "") + ".", notes: notes)
    }

    func performScript(_ args: [String: Any], progress: Progress?) async throws -> String {
        guard let text = args["script"] as? String else { throw APIError(400, "invalid_request", "script is required.") }
        var script = ConversationImporter.parse(text, unnamed: .alternating).script
        guard !script.lines.isEmpty else { throw ServiceError.emptyScript }
        let cast = args["cast"] as? [String: Any] ?? [:]
        var choices: [UUID: APIResolver.VoiceChoice] = [:]
        for s in script.speakers {
            let name = cast.first { $0.key.caseInsensitiveCompare(s.name) == .orderedSame }?.value as? String
            choices[s.id] = await resolver.voice(name)
        }
        let model = try resolver.speechModel(named: args["model"] as? String, for: Array(choices.values))
        var castNotes: [String] = []
        var spare = model.presetVoices.map(\.id)
        for i in script.speakers.indices {
            let s = script.speakers[i]
            let selection = try resolver.selection(choices[s.id] ?? .automatic, for: model)
            if case .preset(let id) = selection { spare.removeAll { $0 == id } }
            script.speakers[i].voice = selection
        }
        // Uncast speakers get different built-in voices, when the model has enough.
        for i in script.speakers.indices where script.speakers[i].voice == .automatic && !spare.isEmpty {
            let id = spare.removeFirst()
            script.speakers[i].voice = .preset(id)
            castNotes.append("\(script.speakers[i].name) → \(model.presetVoices.first { $0.id == id }?.name ?? id)")
        }
        var r = ConversationRequest(modelID: model.id, script: script)
        r.language = args["language"] as? String
        r.post = service.settings.snapshot().postProcessing
        let record = try await APIResolver.finish(service.renderConversation(r), progress: progress)
        let speakers = script.speakers.map(\.name).joined(separator: ", ")
        var notes: [String] = []
        if !castNotes.isEmpty { notes.append("Cast automatically: " + castNotes.joined(separator: ", ") + ".") }
        return try await finished(record, args, summary: "Performed \(script.lines.count) lines (\(speakers)) with \(model.name): "
                                  + "\(Self.seconds(record.duration)).", notes: notes)
    }

    func transcribe(_ args: [String: Any], progress: Progress?) async throws -> String {
        let url = try APIResolver.existingFile(args["path"] as? String, field: "path")
        let model = try resolver.transcriptionModel(named: args["model"] as? String)
        var r = TranscriptionRequest(modelID: model.id, mediaPath: url.path)
        if let l = args["language"] as? String, !l.isEmpty { r.language = l }
        let format = (args["format"] as? String ?? "text").lowercased()
        r.timestamps = args["word_timestamps"] as? Bool == true ? .word : .segment
        let record = try await APIResolver.finish(service.transcribe(r), progress: progress)
        let t = record.transcript
        let formatter = TranscriptFormatter()
        let body: String = switch format {
        case "srt": formatter.srt(t)
        case "vtt": formatter.vtt(t)
        case "json": formatter.json(t)
        case "timestamped": formatter.timestampedText(t)
        default: formatter.plainText(t)
        }
        let language = t.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? t.language
        return "Transcribed \(Self.seconds(t.duration ?? 0)) with \(model.name)" + (language.map { " (\($0))" } ?? "") + ".\n\n" + body
    }

    func changeVoice(_ args: [String: Any], progress: Progress?) async throws -> String {
        let url = try APIResolver.existingFile(args["path"] as? String, field: "path")
        guard case .library(let voice) = await resolver.voice(args["voice"] as? String) else {
            throw APIError(404, "unknown_voice", "change_voice needs one of the user's voices by name. list_voices shows them.")
        }
        let model = try resolver.voiceChangeModel(named: nil)
        let r = VoiceConversionRequest(modelID: model.id, sourcePath: url.path, voice: .library(voice.id))
        let record = try await APIResolver.finish(service.convertVoice(r), progress: progress)
        return try await finished(record, args, summary: "Re-voiced \(url.lastPathComponent) as \(voice.name): \(Self.seconds(record.duration)).",
                                  notes: [])
    }

    func listVoices(_ args: [String: Any]) async throws -> String {
        var lines: [String] = []
        let library = await resolver.libraryVoices()
        lines.append(library.isEmpty ? "The user has no voices of their own yet." : "The user's voices (need a model that clones):")
        for v in library {
            var facts = [v.origin.rawValue]
            if let l = v.language { facts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
            if !v.tags.isEmpty { facts.append("tags: " + v.tags.joined(separator: ", ")) }
            lines.append("- \(v.name) (\(facts.joined(separator: "; ")))" + (v.notes.isEmpty ? "" : ": \(v.notes)"))
        }
        let models: [ModelManifest]
        if let m = try resolver.model(named: args["model"] as? String, task: .tts) { models = [m] } else {
            models = service.catalog.models(for: .tts).filter { service.isDownloaded($0) }
        }
        for m in models where !m.presetVoices.isEmpty {
            lines.append("")
            lines.append("\(m.name) (\(m.id)) built-in voices:")
            for p in m.presetVoices {
                let facts = [p.language, p.gender, p.note].compactMap { $0 }.filter { !$0.isEmpty }
                lines.append("- \(p.name)" + (p.id != p.name ? " [\(p.id)]" : "") + (facts.isEmpty ? "" : " (\(facts.joined(separator: ", ")))"))
            }
        }
        let cloners = service.catalog.models(for: .tts).filter { service.isDownloaded($0) && $0.capabilities.cloning }.map(\.id)
        lines.append("")
        lines.append(cloners.isEmpty ? "No downloaded model can use the user's voices yet." : "Models that can use the user's voices: \(cloners.joined(separator: ", ")).")
        return lines.joined(separator: "\n")
    }

    func listModels() -> String {
        var lines: [String] = []
        for task in ModelTask.allCases {
            let models = service.catalog.models(for: task)
            guard !models.isEmpty else { continue }
            let heading = switch task { case .tts: "Speech:"; case .stt: "Transcription:"; case .voiceConversion: "Voice changer:" }
            lines.append(heading)
            for m in models {
                var facts = [service.isDownloaded(m) ? "downloaded" : "not downloaded"]
                if m.capabilities.cloning { facts.append("uses the user's voices") }
                if !m.presetVoices.isEmpty { facts.append("\(m.presetVoices.count) built-in voice\(m.presetVoices.count == 1 ? "" : "s")") }
                if m.capabilities.styleInstruction { facts.append("takes style directions") }
                if m.languages.count > 1 { facts.append("\(m.languages.count) languages") }
                if m.license.commercialUse == false { facts.append("non-commercial") }
                lines.append("- \(m.id): \(m.name). \(m.summary) (\(facts.joined(separator: ", ")))")
            }
            lines.append("")
        }
        lines.append("Models are downloaded in Encore's Models screen.")
        return lines.joined(separator: "\n")
    }

    /// The common end of a generation tool: export and play if asked, and describe what's where.
    private func finished(_ record: GenerationRecord, _ args: [String: Any], summary: String, notes: [String]) async throws -> String {
        var lines = [summary, "Audio: \(record.audioPath)"]
        if let path = args["output_path"] as? String, !path.isEmpty {
            lines.append("Saved a copy to \(try await APIResolver.export(record, to: path).path).")
        }
        if args["play"] as? Bool == true {
            if let play {
                await play(record.audioURL, record.title)
                lines.append("Playing it now on this Mac.")
            } else {
                lines.append("Playing isn't available here.")
            }
        }
        lines.append("It's also in Encore's History.")
        return (lines + notes).joined(separator: "\n")
    }

    static func seconds(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1f s", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

/// The latest stage text and the last progress sent; says when a new progress notification is due.
final class StageMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private var stage: String?

    /// A stage only updates the text; a fraction at least half a percent past the last one is sent, with the text.
    func update(_ fraction: Double, _ message: String?) -> (Double, String?)? {
        lock.withLock {
            if let message { stage = message }
            guard fraction >= 0, fraction >= last + 0.005 || (fraction >= 1 && last < 1) else { return nil }
            last = min(1, fraction)
            return (last, stage)
        }
    }
}
