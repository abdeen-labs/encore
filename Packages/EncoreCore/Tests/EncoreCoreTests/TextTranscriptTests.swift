import Foundation
import Testing
@testable import EncoreCore

@Suite struct TextTranscriptTests {
    let f = TranscriptFormatter()

    var simple: Transcript {
        Transcript(text: " Hello there. General Kenobi! ", language: "en", duration: 5.5, segments: [
            .init(id: 0, start: 0, end: 1.25, text: " Hello there."),
            .init(id: 1, start: 1.5, end: 3.0049, text: " General Kenobi!"),
        ])
    }

    @Test func plainAndTimestampedText() {
        #expect(f.plainText(simple) == "Hello there. General Kenobi!\n")
        #expect(f.plainText(Transcript(text: "", segments: simple.segments)) == "Hello there. General Kenobi!\n")
        let short = Transcript(text: "x", duration: 70, segments: [.init(id: 0, start: 65.9, end: 69, text: "Later.")])
        #expect(f.timestampedText(short) == "[01:05] Later.\n")
        var long = simple; long.duration = 4000
        #expect(f.timestampedText(long) == "[0:00:00] Hello there.\n[0:00:01] General Kenobi!\n")
    }

    @Test func srtLayout() {
        let srt = f.srt(simple)
        #expect(srt == """
        1
        00:00:00,000 --> 00:00:01,250
        Hello there.

        2
        00:00:01,500 --> 00:00:03,005
        General Kenobi!

        """)
    }

    @Test func vttLayoutAndEscaping() {
        let t = Transcript(text: "", segments: [.init(id: 0, start: 0.5, end: 2, text: "Fish & <chips> --> now")])
        #expect(f.vtt(t) == "WEBVTT\n\n00:00:00.500 --> 00:00:02.000\nFish &amp; &lt;chips&gt; --&gt; now\n")
    }

    @Test func longSegmentWrapsAndSplitsWithinLimits() {
        let text = "This is a fairly long subtitle segment that will certainly not fit within two lines of forty-two characters, so it must be split into more cues."
        let t = Transcript(text: text, segments: [.init(id: 0, start: 10, end: 20, text: text)])
        let cues = f.cues(t)
        #expect(cues.count >= 2)
        for c in cues {
            #expect(c.lines.count <= 2)
            for l in c.lines { #expect(l.count <= 42, "\(l)") }
            #expect(c.start >= 10 && c.end <= 20 && c.end > c.start)
        }
        #expect(cues.flatMap(\.lines).joined(separator: " ") == text)
        for (a, b) in zip(cues, cues.dropFirst()) { #expect(a.end <= b.start) }
    }

    @Test func wordTimingsDriveCueSplits() {
        let words = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
            .split(separator: " ").enumerated().map { i, w in Transcript.Word(start: Double(i), end: Double(i) + 0.8, text: " " + w) }
        let text = words.map(\.text).joined()
        let t = Transcript(text: text, segments: [.init(id: 0, start: 0, end: 20, text: text, words: words)])
        let cues = f.cues(t)
        #expect(cues.count >= 3)
        // Each cue starts exactly at a word start; no cue longer than the max duration.
        for c in cues {
            #expect(c.start == c.start.rounded())
            #expect(c.end - c.start <= f.maxCueDuration + 1)
        }
        #expect(cues.flatMap(\.lines).joined(separator: " ") == text.trimmed())
    }

    @Test func balancedTwoLineWrap() {
        let lines = f.wrap("The quick brown fox jumps over the lazy dog and keeps running")
        #expect(lines.count == 2)
        #expect(abs(lines[0].count - lines[1].count) <= 10)
        #expect(f.wrap("Short line.") == ["Short line."])
    }

    @Test func cjkWidthCountsDouble() {
        let zh = "今天天气很好我们去公园散步吧公园里有很多人在跑步还有小朋友"
        let lines = f.wrap(zh)
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { TranscriptFormatter.width($0) <= 42 })
        #expect(lines.joined() == zh)
    }

    @Test func jsonWithAndWithoutWords() throws {
        let t = Transcript(text: "Hi", language: "en", duration: 1, segments: [
            .init(id: 0, start: 0, end: 1, text: "Hi", words: [.init(start: 0, end: 0.5, text: "Hi")]),
        ])
        let withWords = try JSONDecoder().decode(Transcript.self, from: f.data(t, as: .json))
        #expect(withWords == t)
        var noWords = f; noWords.includeWords = false
        let decoded = try JSONDecoder().decode(Transcript.self, from: noWords.data(t, as: .json))
        #expect(decoded.segments[0].words == nil)
    }

    @Test func textOnlyTranscriptStillMakesSubtitles() {
        let t = Transcript(text: "Just text.", duration: 3)
        #expect(f.srt(t) == "1\n00:00:00,000 --> 00:00:03,000\nJust text.\n")
    }
}
