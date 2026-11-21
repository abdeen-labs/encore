import Foundation
import Testing
@testable import EncoreCore

@Suite struct TextMarkupTests {
    let ava = Voice(name: "Ava Stone", origin: .cloned, transcript: "hi", duration: 3)
    var directory: ScriptVoiceDirectory {
        ScriptVoiceDirectory(library: [ava], presets: [PresetVoice(id: "af_heart", name: "Heart", language: "en", gender: "f", note: nil)])
    }

    func pauses(_ text: String) -> [TimeInterval] { ScriptParser().parse(text).segments.compactMap(\.pauseSeconds) }

    @Test func pauseSpellings() {
        #expect(pauses("a [pause 0.8s] b") == [0.8])
        #expect(pauses("a [pause 500ms] b") == [0.5])
        #expect(pauses("a [pause 2] b") == [2])
        #expect(pauses("a [Pause: 1.5 seconds] b") == [1.5])
        #expect(pauses("a [PAUSE=250 MS] b") == [0.25])
        #expect(pauses("a [pause 1,5s] b") == [1.5])
        #expect(pauses("a [pause .3s] b") == [0.3])
        #expect(pauses("a [pause] b") == [ScriptParser.defaultPauseSeconds])
        #expect(pauses(#"a <break time="1s"/> b"#) == [1])
        #expect(pauses(#"a <break time='750ms' /> b"#) == [0.75])
        #expect(pauses(#"a <BREAK strength="strong"/> b"#) == [0.75])
        #expect(pauses("a <break/> b") == [ScriptParser.defaultPauseSeconds])
    }

    @Test func bareLargeNumberIsMilliseconds() {
        let p = ScriptParser().parse("a [pause 500] b")
        #expect(p.segments.compactMap(\.pauseSeconds) == [0.5])
        #expect(p.issues.contains { $0.severity == .info })
    }

    @Test func malformedAndClampedPauses() {
        let bad = ScriptParser().parse("Hello [pause for effect] there [pause 3h] now")
        #expect(bad.issues.filter { $0.severity == .error }.count == 2)
        #expect(bad.segments.compactMap(\.text) == ["Hello", "there", "now"])
        let long = ScriptParser().parse("a [pause 90s] b")
        #expect(long.segments.compactMap(\.pauseSeconds) == [ScriptParser.maximumPauseSeconds])
        #expect(long.issues.contains { $0.severity == .warning })
    }

    @Test func adjacentPausesMerge() {
        let p = ScriptParser().parse("One.[pause 1s] [pause 500ms]Two.")
        #expect(p.segments.map(\.content) == [.speech("One."), .pause(1.5), .speech("Two.")])
    }

    @Test func tagsAdjacentToPunctuation() {
        let p = ScriptParser().parse("Wait,[pause 0.5s]what?![pause 1s]—no.")
        #expect(p.segments.map(\.content) == [.speech("Wait,"), .pause(0.5), .speech("what?!"), .pause(1), .speech("—no.")])
    }

    @Test func voiceTagsSwitchAndReset() {
        let text = "Narrator here. [voice: ava stone] Hi, I'm Ava. [voice: Heart] And me. [voice: default] Back."
        let p = ScriptParser(voices: directory).parse(text)
        let speech = p.segments.filter { $0.text != nil }
        #expect(speech.map(\.text) == ["Narrator here.", "Hi, I'm Ava.", "And me.", "Back."])
        #expect(speech.map(\.voice) == [nil, .library(ava.id), .preset("af_heart"), nil])
        #expect(p.unknownVoiceNames.isEmpty)
        #expect(p.tags.filter { $0.kind == .voice }.count == 3)
    }

    @Test func voiceMatchingIgnoresCaseDiacriticsAndQuotes() {
        let v = Voice(name: "Zoë", origin: .designed, transcript: "", duration: 2)
        let p = ScriptParser(voices: ScriptVoiceDirectory(library: [v])).parse("[voice: \"ZOE\"] Hello")
        #expect(p.segments.first?.voice == .library(v.id))
        #expect(ScriptParser(voices: directory).parse("[voice=af_heart] x").segments.first?.voice == .preset("af_heart"))
    }

    @Test func unknownVoiceIsReportedAndPreviousContinues() {
        let p = ScriptParser(voices: directory).parse("[voice: Ava Stone] One. [voice: Bob] Two. [voice: bob] Three.")
        #expect(p.unknownVoiceNames == ["Bob"])
        #expect(p.segments.compactMap { $0.text != nil ? $0.voice : nil } == [.library(ava.id), .library(ava.id), .library(ava.id)])
        #expect(p.issues.filter { $0.severity == .warning }.count == 2)
        #expect(ScriptParser().parse("[voice] x").hasErrors)
    }

    @Test func expressiveTagsPassThroughUntouched() {
        let vocab = TagVocabulary(tags: ["[laugh]", "<sigh>", "[S*]", "[confirmation-en]"])
        let text = "[S1] Well [laugh], that's it.<sigh> [s2] Fine [confirmation-en]. </sigh>"
        let p = ScriptParser(vocabulary: vocab).parse(text)
        #expect(p.segments.map(\.content) == [.speech(text)])
        #expect(p.tags.map(\.kind) == Array(repeating: .expressive, count: 6))
        #expect(p.issues.isEmpty)
    }

    @Test func modelTagNamedPauseWinsOverEncore() {
        let p = ScriptParser(vocabulary: TagVocabulary(tags: ["[pause]"])).parse("a [pause] b [pause 1s] c")
        #expect(p.segments.map(\.content) == [.speech("a [pause] b"), .pause(1), .speech("c")])
    }

    @Test func nestedBracketsAndNonTags() {
        let text = "See [note [1]] and [[laugh]] or a<b> and 3 < 4 > 2 and [ ] and [\nbroken]."
        let p = ScriptParser(vocabulary: TagVocabulary(tags: ["[laugh]"])).parse(text)
        #expect(p.segments.map(\.content) == [.speech(text)])
        let kinds = Dictionary(grouping: p.tags, by: \.kind).mapValues { $0.map(\.text) }
        #expect(kinds[.expressive] == ["[laugh]"])
        #expect(kinds[.unrecognized] == ["<b>"])  // "[1]" isn't reported: it doesn't read like an intended tag
    }

    @Test func unknownWordTagIsFlagged() {
        let p = ScriptParser(vocabulary: TagVocabulary(tags: ["[laugh]"])).parse("Ha [giggle] ha")
        #expect(p.tags.map(\.kind) == [.unrecognized])
        #expect(p.issues.first?.severity == .warning)
    }

    @Test func rangesAndUTF16RangesPointAtTheSource() {
        let text = "😀 Héllo [pause 1s] wörld"
        let p = ScriptParser().parse(text)
        let tag = p.tags[0]
        #expect(String(text[tag.range]) == "[pause 1s]")
        #expect((text as NSString).substring(with: tag.utf16Range) == "[pause 1s]")
        for seg in p.segments where seg.text != nil {
            #expect(String(text[seg.range]) == seg.text)
            #expect((text as NSString).substring(with: seg.utf16Range) == seg.text)
        }
    }

    @Test func windowsLineEndings() {
        let p = ScriptParser().parse("Line one.\r\n[pause 1s]\r\nLine two.\r\n")
        #expect(p.segments.map(\.content) == [.speech("Line one."), .pause(1), .speech("Line two.")])
    }

    @Test func emptyAndTagOnlyScripts() {
        #expect(ScriptParser().parse("").segments.isEmpty)
        #expect(ScriptParser().parse("   \n ").segments.isEmpty)
        #expect(ScriptParser().parse("[pause 1s]").segments.map(\.content) == [.pause(1)])
    }
}

@Suite struct TextPronunciationTests {
    func apply(_ entries: [PronunciationEntry], _ text: String) -> String { PronunciationApplier(entries: entries).apply(to: text) }

    @Test func wholeWordsOnly() {
        let e = [PronunciationEntry(term: "Nguyen", replacement: "win")]
        #expect(apply(e, "Mr. Nguyen's car, nguyen. Nguyenville NGUYEN") == "Mr. win's car, win. Nguyenville win")
    }

    @Test func caseSensitivityPerEntry() {
        let e = [PronunciationEntry(term: "US", replacement: "U.S.", caseSensitive: true)]
        #expect(apply(e, "us and US") == "us and U.S.")
    }

    @Test func longestMatchFirstAndNoReReplacement() {
        let e = [PronunciationEntry(term: "New", replacement: "Gnu"),
                 PronunciationEntry(term: "New York", replacement: "Noo Yawk"),
                 PronunciationEntry(term: "Gnu", replacement: "NEW-again"),
                 PronunciationEntry(term: "Yawk", replacement: "nope")]
        #expect(apply(e, "New York and New\nYork, New Jersey") == "Noo Yawk and Noo Yawk, Gnu Jersey")
    }

    @Test func tagsAreUntouched() {
        let e = [PronunciationEntry(term: "laugh", replacement: "laff"), PronunciationEntry(term: "Ava", replacement: "Ah-va"),
                 PronunciationEntry(term: "time", replacement: "tyme")]
        #expect(apply(e, "[laugh] laugh [voice: Ava] Ava <break time=\"1s\"/> time")
                == "[laugh] laff [voice: Ava] Ah-va <break time=\"1s\"/> tyme")
    }

    @Test func unicodeAwareBoundaries() {
        let e = [PronunciationEntry(term: "café", replacement: "ka-fay"), PronunciationEntry(term: "Ωmega", replacement: "omega")]
        #expect(apply(e, "Café, cafés, CAFÉ! Ωmega Ωmegas") == "ka-fay, cafés, ka-fay! omega Ωmegas")
        // Decomposed é (e + combining acute) still matches.
        #expect(apply(e, "cafe\u{301} ok") == "ka-fay ok")
    }

    @Test func cjkTermsNeedNoSpaces() {
        let e = [PronunciationEntry(term: "東京", replacement: "とうきょう"), PronunciationEntry(term: "AI", replacement: "A.I.")]
        #expect(apply(e, "私は東京に住んでいます。AIの研究") == "私はとうきょうに住んでいます。A.I.の研究")
    }

    @Test func apostrophesAndDisabledEntries() {
        let e = [PronunciationEntry(term: "O'Brien", replacement: "Oh Bryan"),
                 PronunciationEntry(term: "skip", replacement: "X", enabled: false),
                 PronunciationEntry(term: "  ", replacement: "blank")]
        #expect(apply(e, "O’Brien said skip") == "Oh Bryan said skip")
    }

    @Test func symbolsAsTerms() {
        let e = [PronunciationEntry(term: "C++", replacement: "C plus plus"), PronunciationEntry(term: "&", replacement: "and")]
        #expect(apply(e, "I like C++ & Swift") == "I like C plus plus and Swift")
    }
}
