import Foundation
import Testing
@testable import EncoreCore

@Suite struct HTTPParserTests {
    @Test func bodyArrivingInPiecesIsReadToItsLength() throws {
        var p = HTTPRequestParser()
        guard case .needMore = p.feed(Data("POST /v1/audio/speech?x=1&y=a%20b HTTP/1.1\r\nHost: localhost:7171\r\nContent-Length: 11\r\n".utf8)) else {
            Issue.record("expected needMore"); return
        }
        guard case .needMore = p.feed(Data("\r\nhello".utf8)) else { Issue.record("expected needMore"); return }
        guard case .complete(let r) = p.feed(Data(" world".utf8)) else { Issue.record("expected a request"); return }
        #expect(r.method == "POST")
        #expect(r.path == "/v1/audio/speech")
        #expect(r.query == ["x": "1", "y": "a b"])
        #expect(r.header("HOST") == "localhost:7171")
        #expect(String(decoding: r.body, as: UTF8.self) == "hello world")
    }

    @Test func chunkedBodiesAreDecoded() throws {
        var p = HTTPRequestParser()
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        guard case .needMore = p.feed(Data((head + "5\r\nhello\r\n").utf8)) else { Issue.record("expected needMore"); return }
        guard case .complete(let r) = p.feed(Data("6;ext=1\r\n world\r\n0\r\n\r\n".utf8)) else { Issue.record("expected a request"); return }
        #expect(String(decoding: r.body, as: UTF8.self) == "hello world")
    }

    @Test func malformedAndOversizedRequestsAreRefused() {
        var bad = HTTPRequestParser()
        if case .failed(let status, _) = bad.feed(Data("GARBAGE\r\n\r\n".utf8)) { #expect(status == 400) } else { Issue.record("expected 400") }

        var big = HTTPRequestParser()
        big.maxBodyBytes = 10
        if case .failed(let status, _) = big.feed(Data("POST / HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8)) {
            #expect(status == 413)
        } else { Issue.record("expected 413") }

        var headers = HTTPRequestParser()
        headers.maxHeaderBytes = 64
        if case .failed(let status, _) = headers.feed(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 100)).utf8)) {
            #expect(status == 431)
        } else { Issue.record("expected 431") }
    }

    @Test func expectContinueIsNoticedBeforeTheBody() {
        var p = HTTPRequestParser()
        _ = p.feed(Data("POST / HTTP/1.1\r\nContent-Length: 3\r\nExpect: 100-continue\r\n\r\n".utf8))
        #expect(p.expectsContinue)
    }

    @Test func multipartFieldsAndFilesAreSplit() throws {
        let body = multipart(fields: ["model": "whisper-1", "response_format": "srt"], file: ("file", "a; b.wav", Data([0, 1, 2, 13, 10])))
        let form = try MultipartForm.parse(body.data, contentType: body.type)
        #expect(form.value("model") == "whisper-1")
        #expect(form.value("response_format") == "srt")
        let file = try #require(form.file("file"))
        #expect(file.filename == "a; b.wav")
        #expect(file.data == Data([0, 1, 2, 13, 10]))
    }
}

/// Builds a multipart/form-data body.
func multipart(fields: [String: String], file: (name: String, filename: String, data: Data)?) -> (data: Data, type: String) {
    let boundary = "----encore\(UUID().uuidString)"
    var d = Data()
    for (k, v) in fields.sorted(by: { $0.key < $1.key }) {
        d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".utf8))
    }
    if let file {
        d.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        d.append(file.data)
        d.append(Data("\r\n".utf8))
    }
    d.append(Data("--\(boundary)--\r\n".utf8))
    return (d, "multipart/form-data; boundary=\(boundary)")
}

@MainActor @Suite struct LocalAPITests {
    nonisolated static let speaker = testManifest("speaker", capabilities: ["presetVoices": true, "cloning": true],
                                                  presets: ["af_heart", "am_adam"],
                                                  reference: ["minSeconds": 3, "maxSeconds": 10, "transcript": "recommended"],
                                                  parameters: [["key": "temperature", "label": "T", "type": "float", "tier": "basic", "default": 0.8]])
    nonisolated static let listener = testManifest("listener", tasks: ["stt"])

    func world() throws -> (ServiceWorld, LocalAPI) {
        let b = FakeBackend(.mlxSwift, features: ["speaker": [.synthesis, .cloning], "listener": [.transcription, .wordTimestamps]])
        let w = try ServiceWorld(models: [Self.speaker, Self.listener], backends: [b])
        return (w, LocalAPI(service: w.service, version: "test"))
    }

    func post(_ path: String, json: Any, headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "POST", path: path, headers: ["Host": "127.0.0.1:7171", "Content-Type": "application/json"].merging(headers) { $1 },
                    body: try! JSONSerialization.data(withJSONObject: json))
    }

    func body(_ r: HTTPResponse) async -> Data {
        switch r.body {
        case .data(let d): return d
        case .stream(let s): var d = Data(); for await c in s { d.append(c) }; return d
        }
    }

    func json(_ r: HTTPResponse) async -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: await body(r))) as? [String: Any] ?? [:]
    }

    @Test func speechComesBackAsAudioAndLandsInHistory() async throws {
        let (w, api) = try world()
        let r = await api.handle(post("/v1/audio/speech", json: ["model": "tts-1", "input": "Hello from the API.", "voice": "alloy",
                                                                 "response_format": "wav"]))
        #expect(r.status == 200)
        #expect(r.headers["Content-Type"] == "audio/wav")
        #expect(r.headers["X-Encore-Model"] == "speaker")
        let audio = await body(r)
        #expect(audio.prefix(4) == Data("RIFF".utf8))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("api-\(UUID().uuidString).wav")
        try audio.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let decoded = try await AudioReader.read(file)
        #expect(abs(decoded.duration - FakeBackend.seconds(for: "Hello from the API.")) < 0.05)
        #expect(try await w.history.count() == 1)
    }

    @Test func unsavedSpeechLeavesNothingBehind() async throws {
        let (w, api) = try world()
        let r = await api.handle(post("/v1/audio/speech", json: ["input": "Just this once.", "response_format": "pcm", "save_to_history": false]))
        #expect(r.status == 200)
        #expect(await body(r).count == Int(FakeBackend.seconds(for: "Just this once.") * 24_000) * 2)
        #expect(try await w.history.count() == 0)
        #expect(w.leftovers().isEmpty)
    }

    @Test func libraryVoicesAreFoundByName() async throws {
        let (w, api) = try world()
        _ = try await w.addVoice("Mira")
        let r = await api.handle(post("/v1/audio/speech", json: ["input": "It's me.", "voice": "mira", "response_format": "wav"]))
        #expect(r.status == 200)
        let items = try await w.history.fetch(limit: 5)
        guard case .generation(let record)? = items.first?.record else { Issue.record("expected a take"); return }
        #expect(record.voiceName == "Mira")
    }

    @Test func unknownNamesSayWhatExists() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let voice = await api.handle(post("/v1/audio/speech", json: ["input": "Hi.", "voice": "Nobody"]))
        #expect(voice.status == 404)
        let error = await json(voice)["error"] as? [String: Any]
        #expect(error?["code"] as? String == "unknown_voice")
        #expect((error?["message"] as? String)?.contains("Af_Heart") == true)

        let model = await api.handle(post("/v1/audio/speech", json: ["input": "Hi.", "model": "nope"]))
        #expect(model.status == 404)
        let format = await api.handle(post("/v1/audio/speech", json: ["input": "Hi.", "response_format": "opus"]))
        #expect(format.status == 400)
        let wrongTask = await api.handle(post("/v1/audio/speech", json: ["input": "Hi.", "model": "listener"]))
        #expect((await json(wrongTask)["error"] as? [String: Any])?["code"] as? String == "wrong_task")
    }

    @Test func webPagesAndOtherHostsAreTurnedAway() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let rebound = HTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "evil.example:7171"])
        #expect(await api.handle(rebound).status == 403)
        let page = HTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "127.0.0.1:7171", "Origin": "https://evil.example"])
        #expect(await api.handle(page).status == 403)
        let local = HTTPRequest(method: "GET", path: "/v1/models", headers: ["Host": "localhost:7171", "Origin": "http://localhost:3000"])
        #expect(await api.handle(local).status == 200)
        let ipv6 = HTTPRequest(method: "GET", path: "/health", headers: ["Host": "[::1]:7171"])
        #expect(await api.handle(ipv6).status == 200)
    }

    @Test func transcriptionUploadsComeBackInTheAskedFormat() async throws {
        let (w, api) = try world()
        let wav = try Data(contentsOf: try w.wav("talk.wav", Signal.speechLike(seconds: 2, rate: 24_000)))
        let form = multipart(fields: ["model": "whisper-1", "response_format": "srt"], file: ("file", "talk.wav", wav))
        let r = await api.handle(HTTPRequest(method: "POST", path: "/v1/audio/transcriptions",
                                             headers: ["Host": "127.0.0.1", "Content-Type": form.type], body: form.data))
        #expect(r.status == 200)
        let srt = String(decoding: await body(r), as: UTF8.self)
        #expect(srt.contains("-->"))
        #expect(srt.contains("Fake transcript."))
    }

    @Test func nativeSpeechStreamsEventsEndingInTheRecord() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let r = await api.handle(post("/v1/speech", json: ["modelID": "speaker", "text": "Streaming events.", "voice": "am_adam"]))
        #expect(r.status == 200)
        #expect(r.headers["Content-Type"] == "application/x-ndjson")
        let lines = String(decoding: await body(r), as: UTF8.self).split(separator: "\n")
        let last = try #require(lines.last.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(last["type"] as? String == "finished")
        #expect((last["record"] as? [String: Any])?["voiceName"] as? String == "Am_Adam")

        let unknown = await api.handle(post("/v1/speech", json: ["modelID": "nope", "text": "Hi."]))
        #expect(unknown.status == 404)
    }

    // MARK: MCP

    func rpc(_ api: LocalAPI, _ method: String, _ params: [String: Any] = [:], id: Any = 1) async -> [String: Any] {
        let r = await api.handle(post("/mcp", json: ["jsonrpc": "2.0", "id": id, "method": method, "params": params],
                                      headers: ["Accept": "application/json, text/event-stream"]))
        return await json(r)
    }

    @Test func mcpHandshakeAndToolList() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let hello = await rpc(api, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                  "clientInfo": ["name": "test", "version": "1"]])
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "encore")

        let note = await api.handle(post("/mcp", json: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        #expect(note.status == 202)

        let tools = (await rpc(api, "tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(Set(tools.compactMap { $0["name"] as? String })
                == ["speak", "perform_script", "transcribe", "change_voice", "list_voices", "list_models"])

        let unknown = await rpc(api, "resources/list")
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test func mcpSpeakMakesATakeAndSavesACopy() async throws {
        let (w, api) = try world()
        let out = w.dir.url.appendingPathComponent("copy.m4a")
        let reply = await rpc(api, "tools/call", ["name": "speak", "arguments": ["text": "Hello, agent.", "output_path": out.path]])
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(text.contains("Saved a copy to \(out.path)"))
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(try await w.history.count() == 1)
    }

    @Test func mcpScriptCastsUncastSpeakersWithDifferentVoices() async throws {
        let (w, api) = try world()
        _ = try await w.addVoice("Mira")
        let reply = await rpc(api, "tools/call", ["name": "perform_script", "arguments": [
            "script": "Ava: Hello there.\nBen: Hi, Ava.\nCal: Hello both.", "cast": ["ava": "Mira"]]])
        let result = try #require(reply["result"] as? [String: Any])
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(result["isError"] as? Bool == false, "\(text)")
        #expect(text.contains("Ben → Af_Heart"))
        #expect(text.contains("Cal → Am_Adam"))
    }

    @Test func mcpToolErrorsAreResultsNotProtocolErrors() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let reply = await rpc(api, "tools/call", ["name": "transcribe", "arguments": ["path": "/no/such/file.wav"]])
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test func mcpProgressStreamsAsEventsBeforeTheResult() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let r = await api.handle(post("/mcp", json: ["jsonrpc": "2.0", "id": 7, "method": "tools/call",
                                                     "params": ["name": "speak", "arguments": ["text": "With progress."],
                                                                "_meta": ["progressToken": "p1"]]],
                                      headers: ["Accept": "application/json, text/event-stream"]))
        #expect(r.headers["Content-Type"] == "text/event-stream")
        let events = String(decoding: await body(r), as: UTF8.self).components(separatedBy: "\n\n").filter { !$0.isEmpty }
        let messages = events.compactMap { e in
            e.split(separator: "\n").first { $0.hasPrefix("data: ") }
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.dropFirst(6).utf8)) as? [String: Any] }
        }
        #expect(messages.dropLast().allSatisfy { $0["method"] as? String == "notifications/progress" })
        #expect(messages.count >= 2)
        #expect(messages.last?["id"] as? Int == 7)
        let progress = messages.dropLast().compactMap { ($0["params"] as? [String: Any])?["progress"] as? Double }
        #expect(progress == progress.sorted() && Set(progress).count == progress.count)
    }

    // MARK: Over the network

    @Test func serverAnswersOnLoopback() async throws {
        let (w, api) = try world(); defer { withExtendedLifetime(w) {} }
        let server = LocalHTTPServer(port: 0) { await api.handle($0) }
        try await server.start()
        defer { server.stop() }
        let port = try #require(server.boundPort)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["input": "Over the wire.", "response_format": "wav"])
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.prefix(4) == Data("RIFF".utf8))

        // A streamed (chunked) response ends, so the client isn't left waiting.
        var streamed = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/speech")!, timeoutInterval: 10)
        streamed.httpMethod = "POST"
        streamed.httpBody = try JSONSerialization.data(withJSONObject: ["modelID": "speaker", "text": "Streamed."])
        let (lines, _) = try await URLSession.shared.data(for: streamed)
        #expect(String(decoding: lines, as: UTF8.self).contains("\"type\":\"finished\""))

        let second = LocalHTTPServer(port: port) { _ in .empty(204) }
        await #expect(throws: LocalHTTPServer.StartError.portInUse(port)) { try await second.start() }
    }
}
