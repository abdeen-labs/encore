import Foundation
import Testing
@testable import EncoreCore

@Suite struct StoreHistoryTests {
    let dir: TempDir
    let db: HistoryDatabase
    let base = Date(timeIntervalSince1970: 1_750_000_000)

    init() throws {
        dir = try TempDir()
        db = try HistoryDatabase(directory: dir.url)
    }

    func generation(_ title: String, text: String = "", kind: GenerationRecord.Kind = .speech, model: String = "kokoro",
                    voice: String? = nil, voiceID: UUID? = nil, minutes: Double = 0, favorite: Bool = false) throws -> GenerationRecord {
        let id = UUID()
        let url = db.newAudioURL(id: id)
        try Data("wav".utf8).write(to: url)
        return GenerationRecord(id: id, kind: kind, title: title, text: text, modelID: model, modelName: model.capitalized,
                                voiceName: voice, voiceID: voiceID, parameters: ["speed": .double(1.1)], audioPath: url.path,
                                duration: 2, sampleRate: 24000, createdAt: base.addingTimeInterval(minutes * 60), favorite: favorite)
    }

    func transcription(_ name: String, text: String, minutes: Double = 0) -> TranscriptionRecord {
        TranscriptionRecord(sourceName: name, sourcePath: "/Users/someone/Movies/\(name)", modelID: "whisper", modelName: "Whisper",
                            transcript: Transcript(text: text, language: "en", duration: 9,
                                                   segments: [.init(id: 0, start: 0, end: 9, text: text)]),
                            createdAt: base.addingTimeInterval(minutes * 60))
    }

    func titles(_ q: HistoryQuery) async throws -> [String] { try await db.fetch(q).map(\.title) }

    @Test func insertFetchRoundTripAndOrder() async throws {
        let g = try generation("Hello", text: "Hello world", minutes: 1)
        let t = transcription("talk.mp4", text: "We talked about cafés.", minutes: 2)
        try await db.insert(g)
        try await db.insert(t)
        let items = try await db.fetch()
        #expect(items.map(\.title) == ["talk.mp4", "Hello"])
        #expect(items[1].generation == g)
        #expect(items[0].transcription == t)
        #expect(items[0].kind == .transcription && items[1].kind == .speech)
        #expect(try await db.item(g.id)?.generation == g)
        #expect(try await db.count() == 2)

        // Survives reopening (migrations already applied).
        let reopened = try HistoryDatabase(directory: dir.url)
        #expect(try await reopened.fetch().map(\.id) == [t.id, g.id])
    }

    @Test func paging() async throws {
        for i in 0..<25 { try await db.insert(try generation("Item \(i)", minutes: Double(i))) }
        let first = try await db.fetch(limit: 10)
        let second = try await db.fetch(limit: 10, offset: 10)
        let third = try await db.fetch(limit: 10, offset: 20)
        #expect(first.first?.title == "Item 24" && first.count == 10)
        #expect(second.first?.title == "Item 14")
        #expect(third.map(\.title) == (0..<5).reversed().map { "Item \($0)" })
        #expect(Set((first + second + third).map(\.id)).count == 25)
    }

    @Test func filters() async throws {
        let ava = UUID()
        try await db.insert(try generation("A", kind: .speech, model: "kokoro", minutes: 0))
        try await db.insert(try generation("B", kind: .conversation, model: "qwen3", voice: "Ava", voiceID: ava, minutes: 10, favorite: true))
        try await db.insert(try generation("C", kind: .voiceChange, model: "chatterbox", voiceID: ava, minutes: 20))
        try await db.insert(transcription("D", text: "words", minutes: 30))
        #expect(try await titles(.init(kinds: [.speech, .transcription])) == ["D", "A"])
        #expect(try await titles(.init(favoritesOnly: true)) == ["B"])
        #expect(try await titles(.init(modelID: "qwen3")) == ["B"])
        #expect(try await titles(.init(voiceID: ava)) == ["C", "B"])
        #expect(try await titles(.init(from: base.addingTimeInterval(600), until: base.addingTimeInterval(1800))) == ["C", "B"])
        #expect(try await db.count(.init(kinds: [.voiceDesign])) == 0)
    }

    @Test func fullTextSearch() async throws {
        try await db.insert(try generation("Morning news", text: "General Kenobi arrived at the café.", model: "kokoro", voice: "Zoë"))
        try await db.insert(try generation("Bedtime", text: "Rock'n'roll lullaby, sung softly.", model: "qwen3", voice: "Bram"))
        try await db.insert(transcription("interview.mov", text: "The quarterly numbers were excellent."))
        #expect(try await titles(.init(search: "gen")) == ["Morning news"])            // prefix as you type
        #expect(try await titles(.init(search: "cafe")) == ["Morning news"])           // diacritics ignored
        #expect(try await titles(.init(search: "ZOE")) == ["Morning news"])            // voice name
        #expect(try await titles(.init(search: "qwen")) == ["Bedtime"])                // model name
        #expect(try await titles(.init(search: "quarter numb")) == ["interview.mov"])  // transcript text, all words
        #expect(try await titles(.init(search: "quarter kenobi")).isEmpty)
        #expect(try await titles(.init(search: "rock'n'roll!!")) == ["Bedtime"])      // punctuation in the query
        #expect(try await titles(.init(search: "bed")) == ["Bedtime"])                 // title
        // FTS syntax in the query is inert.
        for weird in ["\"", "AND", "OR (", "NOT*", "a:b", "-", "^", "{x}", "NEAR(", "*"] {
            _ = try await db.fetch(.init(search: weird))
        }
        #expect(try await db.fetch(.init(search: "!!!")).count == 3)                   // nothing searchable: no filter
        #expect(try await titles(.init(search: "softly", kinds: [.transcription])).isEmpty)
    }

    @Test func cjkSearchBySubstring() async throws {
        try await db.insert(try generation("日本語", text: "今日は良い天気ですね。"))
        try await db.insert(try generation("English", text: "Nice weather."))
        #expect(try await titles(.init(search: "天気")) == ["日本語"])
        #expect(try await titles(.init(search: "100%_")).isEmpty)
    }

    @Test func titleAndFavoriteUpdates() async throws {
        let g = try generation("Old", text: "x")
        let t = transcription("clip.wav", text: "hello")
        try await db.insert(g); try await db.insert(t)
        try await db.setTitle("  New   title ", for: g.id)
        try await db.setFavorite(true, for: g.id)
        try await db.setTitle("My interview", for: t.id)
        try await db.setFavorite(true, for: t.id)
        let gi = try #require(try await db.item(g.id))
        #expect(gi.title == "New title" && gi.favorite && gi.generation?.title == "New title" && gi.generation?.favorite == true)
        let ti = try #require(try await db.item(t.id))
        #expect(ti.title == "My interview" && ti.favorite && ti.transcription?.sourceName == "clip.wav")
        #expect(try await titles(.init(search: "interview")) == ["My interview"])

        var edited = t
        edited.transcript.text = "hello again"
        try await db.update(edited)
        let after = try #require(try await db.item(t.id))
        #expect(after.title == "My interview" && after.favorite && after.transcription?.transcript.text == "hello again")
        #expect(try await titles(.init(search: "again")) == ["My interview"])

        var g2 = gi.generation!
        g2.duration = 9
        try await db.update(g2)
        #expect(try await db.item(g.id)?.generation?.duration == 9)
        await #expect(throws: StoreError.self) { try await db.setFavorite(true, for: UUID()) }
    }

    @Test func deleteRemovesOwnedAudioOnly() async throws {
        let owned = try generation("Owned")
        let externalURL = dir.url.appendingPathComponent("elsewhere.wav")
        try Data("keep".utf8).write(to: externalURL)
        var external = try generation("External")
        try FileManager.default.removeItem(atPath: external.audioPath)
        external.audioPath = externalURL.path
        let t = transcription("source.mov", text: "x")
        try await db.insert(owned); try await db.insert(external); try await db.insert(t)
        try await db.delete([owned.id, external.id, t.id, UUID()])
        #expect(try await db.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: owned.audioPath))
        #expect(FileManager.default.fileExists(atPath: externalURL.path))
        #expect(try await db.fetch(.init(search: "owned")).isEmpty) // FTS index follows deletes
    }

    @Test func newAudioURLIsInsideHistory() {
        let id = UUID()
        let url = db.newAudioURL(id: id, fileExtension: "m4a")
        #expect(url.lastPathComponent == "\(id.uuidString).m4a")
        #expect(url.deletingLastPathComponent() == db.audioDirectory)
        #expect(db.ownsAudio(url.path))
        #expect(!db.ownsAudio(dir.url.appendingPathComponent("x.wav").path))
        #expect(!db.ownsAudio(db.audioDirectory.path + "/../history.sqlite"))
    }

    @MainActor @Test func observableStoreFollowsTheDatabase() async throws {
        let store = HistoryStore(database: db, pageSize: 3)
        await waitUntil { !store.isLoading }
        #expect(store.items.isEmpty)

        // A write from elsewhere (the service layer) shows up.
        let g = try generation("First", text: "alpha", minutes: 0)
        try await Task.detached { [db] in try await db.insert(g) }.value
        await waitUntil { store.items.map(\.id) == [g.id] }

        for i in 1...4 { try await db.insert(try generation("More \(i)", text: "beta", minutes: Double(i))) }
        await waitUntil { store.totalCount == 5 }
        #expect(store.items.count == 3 && store.hasMore)
        store.loadMore()
        await waitUntil { store.items.count == 5 }
        #expect(!store.hasMore)

        store.query.search = "alp"
        await waitUntil { store.items.map(\.title) == ["First"] }
        #expect(store.totalCount == 1)

        try await store.setFavorite(true, for: g.id)
        await waitUntil { store.items.first?.favorite == true }
        store.query = HistoryQuery(favoritesOnly: true)
        await waitUntil { store.items.map(\.id) == [g.id] }
        try await store.delete([g.id])
        await waitUntil { store.items.isEmpty && store.totalCount == 0 }
    }
}
