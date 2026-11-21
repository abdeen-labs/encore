import Foundation
import Testing
@testable import EncoreCore

@Suite struct TextChunkerTests {
    func chunk(_ text: String, _ max: Int) -> [TextChunk] { TextChunker(maxCharacters: max).chunks(of: text) }
    func texts(_ text: String, _ max: Int) -> [String] { chunk(text, max).map(\.text) }

    /// Every chunk is a trimmed slice of the source, within the limit, in order, covering all non-space text.
    func checkInvariants(_ text: String, _ max: Int, allowOverflow: Bool = false, sourceLocation: SourceLocation = #_sourceLocation) {
        let chunks = chunk(text, max)
        var last = text.startIndex
        for c in chunks {
            #expect(String(text[c.range]) == c.text, sourceLocation: sourceLocation)
            #expect((text as NSString).substring(with: c.utf16Range) == c.text, sourceLocation: sourceLocation)
            #expect(c.text == c.text.trimmed() && !c.text.isEmpty, sourceLocation: sourceLocation)
            if !allowOverflow { #expect(c.text.count <= max, "\(c.text.count) > \(max): \(c.text)", sourceLocation: sourceLocation) }
            #expect(c.range.lowerBound >= last, sourceLocation: sourceLocation)
            let gapIsSpace = text[last..<c.range.lowerBound].allSatisfy { $0.isWhitespace }
            #expect(gapIsSpace, sourceLocation: sourceLocation)
            last = c.range.upperBound
        }
        let tailIsSpace = text[last...].allSatisfy { $0.isWhitespace }
        #expect(tailIsSpace, sourceLocation: sourceLocation)
        #expect(chunks.last?.boundary == .end || chunks.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func shortTextIsOneChunk() {
        #expect(texts("  Hello there.  ", 100) == ["Hello there."])
        #expect(chunk("Hi.", 100).first?.boundary == .end)
        #expect(texts("", 100).isEmpty)
        #expect(texts(" \n\n ", 100).isEmpty)
    }

    @Test func sentenceBoundariesPreferred() {
        let text = "The first sentence is here. The second one follows it. A third sentence ends the paragraph."
        let c = chunk(text, 60)
        #expect(c.map(\.text) == ["The first sentence is here. The second one follows it.", "A third sentence ends the paragraph."])
        #expect(c[0].boundary == .sentence)
        checkInvariants(text, 60)
    }

    @Test func abbreviationsNumbersAndEllipses() {
        let text = "Dr. Smith paid $3.50… for a coffee at 7 a.m. on Main St. in the U.S. today. Then Mrs. J. R. Jones arrived, e.g. late. It was fine."
        // Only real sentence ends are candidates: after "today." and "late." and "fine."
        let c = chunk(text, 110)
        #expect(c.map(\.text) == [
            "Dr. Smith paid $3.50… for a coffee at 7 a.m. on Main St. in the U.S. today.",
            "Then Mrs. J. R. Jones arrived, e.g. late. It was fine.",
        ])
        checkInvariants(text, 110)
        let analysed = TextChunker.breakStrengths(text, chars: Array(text), idx: Array(text.indices) + [text.endIndex], tags: [])
        let sentenceOffsets = analysed.enumerated().filter { $0.element == .sentence }.map(\.offset)
        let chars = Array(text)
        let ends = sentenceOffsets.map { String(chars[max(0, $0 - 5)..<$0]) }
        #expect(ends == ["oday.", "late."])
    }

    @Test func ellipsisBeforeCapitalEndsSentence() {
        let a = TextChunker.breakStrengths("Wait... Now go.", chars: Array("Wait... Now go."),
                                           idx: Array("Wait... Now go.".indices) + ["Wait... Now go.".endIndex], tags: [])
        #expect(a[7] == .sentence)
    }

    @Test func quotesStayWithTheirSentence() {
        let text = "He said, “Go now.” She left. “Really?” she asked. Yes."
        let c = chunk(text, 30)
        #expect(c.map(\.text).first == "He said, “Go now.” She left.")
        #expect(!c.map(\.text).contains { $0.hasPrefix("”") || $0.hasPrefix("she") })
        checkInvariants(text, 30)
    }

    @Test func fallsBackToClausesThenWords() {
        let clause = "This sentence is long, with several clauses, each separated by commas, and no period anywhere in it"
        let c = chunk(clause, 50)
        #expect(c.allSatisfy { $0.text.count <= 50 })
        #expect(c[0].boundary == .clause && c[0].text.hasSuffix(","))
        checkInvariants(clause, 50)

        let words = String(repeating: "word ", count: 100)
        let w = chunk(words, 37)
        #expect(w.allSatisfy { $0.text.split(separator: " ").allSatisfy { $0 == "word" } })
        checkInvariants(words, 37)
    }

    @Test func veryLongUnpunctuatedRun() {
        let blob = String(repeating: "x", count: 1000)
        let c = chunk(blob, 300)
        #expect(c.map(\.text.count).reduce(0, +) == 1000)
        #expect(c.allSatisfy { $0.boundary == .forced || $0.boundary == .end })
        checkInvariants(blob, 300)
    }

    @Test func cjkText() {
        let zh = "今天天气很好，我们去公园散步吧。公园里有很多人在跑步，还有小朋友在玩耍。我们走了一个小时，然后回家吃饭了。晚上我们看了一部电影。"
        let c = chunk(zh, 25)
        #expect(c.count >= 3)
        #expect(c[0].text == "今天天气很好，我们去公园散步吧。")
        #expect(c.allSatisfy { $0.boundary != .forced })
        checkInvariants(zh, 25)

        let ja = "吾輩は猫である名前はまだ無いどこで生れたかとんと見当がつかぬ何でも薄暗いじめじめした所でニャーニャー泣いていた事だけは記憶している"
        let j = chunk(ja, 20)
        #expect(j.allSatisfy { $0.boundary == .word || $0.boundary == .end }, "\(j.map(\.text))")
        checkInvariants(ja, 20)
    }

    @Test func thaiUsesDictionaryWordBreaks() {
        let th = "ภาษาไทยเป็นภาษาที่ไม่มีการเว้นวรรคระหว่างคำซึ่งทำให้การตัดคำเป็นเรื่องยาก"
        let c = chunk(th, 20)
        #expect(c.allSatisfy { $0.boundary == .word || $0.boundary == .end })
        checkInvariants(th, 20)
    }

    @Test func neverSplitsInsideTags() {
        let text = "Alpha beta [pause 1.5s] gamma <break time=\"500ms\"/> delta [laugh] epsilon zeta eta theta"
        for limit in 5...40 {
            let c = chunk(text, limit)
            for tag in ["[pause 1.5s]", "<break time=\"500ms\"/>", "[laugh]"] {
                #expect(c.contains { $0.text.contains(tag) }, "limit \(limit) split \(tag): \(c.map(\.text))")
            }
            checkInvariants(text, limit, allowOverflow: true)
        }
    }

    @Test func paragraphsAlwaysSplitAndReportBoundary() {
        let text = "Chapter One\n\nIt was a dark night.\nThe wind blew.\r\n\r\nThe end."
        let c = chunk(text, 500)
        #expect(c.map(\.text) == ["Chapter One", "It was a dark night.\nThe wind blew.", "The end."])
        #expect(c.map(\.boundary) == [.paragraph, .paragraph, .end])
        checkInvariants(text, 500)
        #expect(chunk("a\n  \t\nb", 0).map(\.text) == ["a", "b"])
    }

    @Test func singleNewlineIsAClauseBoundary() {
        let text = "first line without punctuation\nsecond line without punctuation\nthird line"
        let c = chunk(text, 40)
        #expect(c.map(\.text) == ["first line without punctuation", "second line without punctuation", "third line"])
        #expect(c[0].boundary == .clause)
        checkInvariants(text, 40)
    }

    @Test func avoidsTinyTrailingChunk() {
        let text = "This is the first sentence of reasonable length here. This is a second sentence also here. Ok."
        let c = chunk(text, 92)
        // Greedy packing would leave "Ok." alone; rebalancing moves the split to the middle sentence end.
        #expect(c.map(\.text) == ["This is the first sentence of reasonable length here.", "This is a second sentence also here. Ok."])
        checkInvariants(text, 92)
    }

    @Test func rangesReferToEnclosingText() {
        let text = "Prefix [voice: X] Hello there. General Kenobi. You are a bold one."
        let start = text.range(of: "Hello")!.lowerBound
        let c = TextChunker(maxCharacters: 20).chunks(of: text, in: start..<text.endIndex)
        #expect(c.map(\.text) == ["Hello there.", "General Kenobi.", "You are a bold one."])
        for x in c { #expect(String(text[x.range]) == x.text) }
    }

    @Test func emojiAndCombiningCharactersCountAsOne() {
        let text = String(repeating: "👩‍👩‍👧‍👦", count: 30)
        let c = chunk(text, 10)
        #expect(c.map(\.text.count) == [10, 10, 10])
    }

    @Test func fuzzInvariants() {
        var rng = SystemRandomNumberGenerator()
        let pieces = ["Hello", "world", ".", ",", " ", " ", "\n", "\n\n", "[pause 1s]", "[laugh]", "Dr.", "3.50", "…", "今日は",
                      "。", "“Quote.”", "<break time=\"1s\"/>", "\r\n", "e.g.", "?!", "—", "Ünïcödé"]
        for _ in 0..<200 {
            let text = (0..<Int.random(in: 0...80, using: &rng)).map { _ in pieces.randomElement(using: &rng)! }.joined()
            let limit = Int.random(in: 20...120, using: &rng)
            checkInvariants(text, limit)
        }
    }
}

@Suite struct TextPlannerTests {
    @Test func planCombinesMarkupChunkingAndPronunciations() {
        let ava = Voice(name: "Ava", origin: .cloned, transcript: "", duration: 2)
        let planner = ScriptPlanner(
            parser: ScriptParser(vocabulary: TagVocabulary(tags: ["[laugh]"]), voices: ScriptVoiceDirectory(library: [ava])),
            maxChunkCharacters: 40,
            pronunciations: [PronunciationEntry(term: "Nguyen", replacement: "win"), PronunciationEntry(term: "laugh", replacement: "X")],
            chunkGap: 0.2, paragraphGap: 0.6)
        let script = "Mr. Nguyen arrived. He sat down [laugh] and waited.\n\nNew paragraph here. [pause 1s] [voice: Ava] Hello,\n Nguyen!"
        let plan = planner.plan(script)
        let chunks = plan.chunks
        #expect(chunks.map(\.text) == ["Mr. win arrived.", "He sat down [laugh] and waited.", "New paragraph here.", "Hello, win!"])
        #expect(chunks.map(\.gapAfter) == [0.2, 0.6, 0, 0])
        #expect(chunks.map(\.voice) == [nil, nil, nil, .library(ava.id)])
        #expect(chunks.map { String(script[$0.range]) } == chunks.map(\.sourceText))
        #expect(plan.items.contains(.pause(1, range: script.range(of: "[pause 1s]")!)))
    }

    @Test func plannerFromRequest() {
        var manifest = try! JSONDecoder().decode(ModelManifest.self, from: Data(TestManifest.json.utf8))
        manifest.maxChunkCharacters = 30
        var request = SpeechRequest(modelID: manifest.id, text: "")
        request.autoChunk = false
        let p = ScriptPlanner(request: request, manifest: manifest, library: [], pronunciations: [])
        #expect(p.maxChunkCharacters == nil)
        let plan = p.plan("[voice: Heart] This is a long sentence that would be chunked. [chuckle]")
        #expect(plan.chunks.count == 1)
        #expect(plan.chunks[0].voice == .preset("af_heart"))
        #expect(plan.parsed.tags.map(\.kind) == [.voice, .expressive])
    }
}

enum TestManifest {
    static let json = """
    {"id":"test-tts","name":"Test","family":"Test","summary":"","tasks":["tts"],"engine":"test",
     "variants":[{"id":"v","label":"bf16","repo":"org/test","downloadBytes":1,"memoryBytes":1}],
     "license":{"name":"MIT"},"capabilities":{"presetVoices":true},"languages":[],
     "presetVoices":[{"id":"af_heart","name":"Heart"}],
     "expressiveTags":[{"tag":"[chuckle]","label":"Chuckle"}],
     "parameters":[],"maxChunkCharacters":300,"sampleRate":24000}
    """
}
