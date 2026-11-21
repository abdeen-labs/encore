import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import EncoreCore

@Suite struct TextConversationTests {
    func names(_ r: ConversationImporter.Result) -> [String] { r.script.speakers.map(\.name) }
    func turns(_ r: ConversationImporter.Result) -> [String] {
        let byID = Dictionary(uniqueKeysWithValues: r.script.speakers.map { ($0.id, $0.name) })
        return r.script.lines.map { "\(byID[$0.speakerID]!): \($0.text)" }
    }

    @Test func labeledScript() {
        let text = """
        Alice: Hi there.
        Bob: Hello,
        how are you doing to-
        day?

        Still Bob here, new paragraph.
        alice: Fine, thanks. It's 3:45 now.
        """
        let r = ConversationImporter.parse(text)
        #expect(r.layout == .labeled)
        #expect(names(r) == ["Alice", "Bob"])
        #expect(turns(r) == ["Alice: Hi there.", "Bob: Hello, how are you doing today?",
                             "Bob: Still Bob here, new paragraph.", "Alice: Fine, thanks. It's 3:45 now."])
    }

    @Test func labeledVariants() {
        let text = "Title: Episode 1: The Return\r\n\r\n**Dr. Ava Stone:** Welcome back.\r\n[00:01:02] Narrator (whispering): Quietly.\r\nNARRATOR:\r\nOn the next line. [pause 1.2s]\r\n(They leave.)\r\n\r\nNote: not a speaker\r\n"
        let r = ConversationImporter.parse(text)
        #expect(r.script.title == "Episode 1: The Return")
        #expect(names(r) == ["Dr. Ava Stone", "Narrator"])
        #expect(turns(r) == ["Dr. Ava Stone: Welcome back.", "Narrator: Quietly.",
                             "Narrator: On the next line.", "Narrator: Note: not a speaker"])
        #expect(r.script.lines[2].pauseAfter == 1.2)
        #expect(r.notes.contains { $0.contains("stage direction") })
    }

    @Test func trailingPauseBecomesPauseAfter() {
        let r = ConversationImporter.parse("A: One. [pause 1.2s]\nB: Two [pause 500ms]\n")
        #expect(r.script.lines.map(\.pauseAfter) == [1.2, 0.5])
        #expect(r.script.lines.map(\.text) == ["One.", "Two"])
    }

    @Test func screenplayText() {
        let text = """
        THE LONG NIGHT

        INT. KITCHEN - NIGHT

        Rain hammers the window. JOHN stirs a pot.

                            JOHN
                  (without looking up)
                  You're late.

                            MARY (O.S.)
                  The bridge was out.
                  I had to walk.

        She enters, soaked.

                            JOHN (CONT'D)
                  Sit. Eat.

        CUT TO:
        """
        let r = ConversationImporter.parse(text)
        #expect(r.layout == .screenplay)
        #expect(r.script.title == "THE LONG NIGHT")
        #expect(names(r) == ["John", "Mary"])
        #expect(turns(r) == ["John: You're late.", "Mary: The bridge was out. I had to walk.", "John: Sit. Eat."])
        #expect(!r.notes.isEmpty)
    }

    @Test func unlabeledParagraphsAlternate() {
        let r = ConversationImporter.parse("Hello there,\nfriend.\n\nHi yourself.\n\n\nBye.")
        #expect(r.layout == .paragraphs)
        #expect(turns(r) == ["Speaker 1: Hello there, friend.", "Speaker 2: Hi yourself.", "Speaker 1: Bye."])
    }

    @Test func speakersInOrderOfFirstAppearance() {
        let r = ConversationImporter.parse("Zed: a\nAmy: b\nZED: c\nMo: d")
        #expect(names(r) == ["Zed", "Amy", "Mo"])
        #expect(Set(r.script.lines.map(\.speakerID)).count == 3)
    }

    @Test func roundTrip() {
        var script = ConversationScript()
        script.title = "Pilot: Part 1"
        let a = ConversationScript.Speaker(name: "Ava"), b = ConversationScript.Speaker(name: "Bo Diddley")
        script.speakers = [a, b]
        var l1 = ConversationScript.Line(speakerID: a.id, text: "Hello:\nthere.")
        l1.pauseAfter = 1.5
        var l2 = ConversationScript.Line(speakerID: b.id, text: "Hi [laugh] Ava.")
        l2.pauseAfter = 2
        script.lines = [l1, l2, .init(speakerID: a.id, text: "Bye.")]
        let text = ConversationImporter.text(for: script)
        #expect(text == "Title: Pilot: Part 1\n\nAva: Hello: there. [pause 1500ms]\nBo Diddley: Hi [laugh] Ava. [pause 2s]\nAva: Bye.\n")
        let back = ConversationImporter.parse(text).script
        #expect(back.title == script.title)
        #expect(back.speakers.map(\.name) == ["Ava", "Bo Diddley"])
        #expect(back.lines.map(\.text) == ["Hello: there.", "Hi [laugh] Ava.", "Bye."])
        #expect(back.lines.map(\.pauseAfter) == [1.5, 2, nil])
    }

    @Test func importTextFileWithEncodings() throws {
        let dir = try TempDir()
        let utf16 = dir.url.appendingPathComponent("s.txt")
        try "Ana: Olá!\nJosé: Tudo bem?".data(using: .utf16)!.write(to: utf16)
        let r = try ConversationImporter.importFile(at: utf16)
        #expect(names(r) == ["Ana", "José"])
        #expect(r.script.title == "s")
        let latin1 = dir.url.appendingPathComponent("l.txt")
        try "Zoë: Café?\nMax: Oui.".data(using: .windowsCP1252)!.write(to: latin1)
        #expect(turns(try ConversationImporter.importFile(at: latin1)) == ["Zoë: Café?", "Max: Oui."])
        #expect(throws: ConversationImporter.Failure.self) {
            try ConversationImporter.importFile(at: dir.url.appendingPathComponent("x.docx"))
        }
    }

    // MARK: PDF

    /// Draws lines of text at given positions (points from the bottom-left), one array per page.
    static func makePDF(_ pages: [[(String, CGFloat, CGFloat)]], at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Courier" as CFString, 12, nil)
        for page in pages {
            ctx.beginPDFPage(nil)
            for (text, x, y) in page {
                let s = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
                ctx.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    @Test func labeledPDFWithHeadersFootersAndWraps() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("interview.pdf")
        func page(_ n: Int, _ body: [String]) -> [(String, CGFloat, CGFloat)] {
            var lines: [(String, CGFloat, CGFloat)] = [("THE PODCAST — DRAFT 3", 72, 750)]
            var y: CGFloat = 700
            for l in body {
                if l.isEmpty { y -= 14; continue }
                lines.append((l, 72, y)); y -= 14
            }
            lines.append(("\(n)", 300, 40))
            return lines
        }
        Self.makePDF([
            page(1, ["Host: Welcome to the show. Today we are", "talking about extra-", "ordinary voices.", "",
                     "Guest: Thanks for having me."]),
            page(2, ["Host: Let's begin with your first", "record.", "", "Guest: Sure."]),
        ], at: url)
        let r = try ConversationImporter.importFile(at: url)
        #expect(names(r) == ["Host", "Guest"])
        #expect(turns(r) == ["Host: Welcome to the show. Today we are talking about extraordinary voices.",
                             "Guest: Thanks for having me.", "Host: Let's begin with your first record.", "Guest: Sure."])
        #expect(r.script.title == "interview")
    }

    @Test func screenplayPDF() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("scene.pdf")
        // Standard screenplay margins: action 1.5", dialogue 2.5", parenthetical 3.1", cue 3.7". 12-pt lines.
        var p1: [(String, CGFloat, CGFloat)] = []
        var y: CGFloat = 720
        func add(_ s: String, _ x: CGFloat) { p1.append((s, x, y)); y -= 12 }
        func blank() { y -= 12 }
        add("INT. LIGHTHOUSE - NIGHT", 108); blank()
        add("Waves crash below. KEEPER climbs the stairs.", 108); blank()
        add("KEEPER", 266)
        add("(out of breath)", 223)
        add("Every night the same climb.", 180)
        add("Every night the same light.", 180); blank()
        add("VISITOR (O.S.)", 266)
        add("Hello? Is anyone up there?", 180)
        add("(MORE)", 266)
        p1.append(("1.", 520, 750))
        var p2: [(String, CGFloat, CGFloat)] = [("2.", 520, 750)]
        y = 720
        p2.append(("VISITOR (CONT'D)", 266, y)); y -= 12
        p2.append(("I saw the light go out.", 180, y)); y -= 24
        p2.append(("KEEPER", 266, y)); y -= 12
        p2.append(("It never goes out.", 180, y)); y -= 24
        p2.append(("He freezes.", 108, y))
        Self.makePDF([p1, p2], at: url)

        let r = try ConversationImporter.importFile(at: url)
        #expect(r.layout == .screenplay)
        #expect(names(r) == ["Keeper", "Visitor"])
        #expect(turns(r) == ["Keeper: Every night the same climb. Every night the same light.",
                             "Visitor: Hello? Is anyone up there? I saw the light go out.",
                             "Keeper: It never goes out."])
    }

    @Test func pdfWithoutTextFails() throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("blank.pdf")
        Self.makePDF([[]], at: url)
        #expect(throws: PDFTextExtractor.Failure.self) { try ConversationImporter.importFile(at: url) }
    }
}

/// A temporary directory removed when the value is deallocated.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("EncoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
