#if DEBUG
import AppKit
import CoreText
import EncoreCore
import Foundation

/// The Conversations screen's own model rendering real scripts: a labeled .txt and a screenplay printed to .pdf are
/// imported, cast with preset voices and rendered; then one line is edited and the script re-rendered, showing that
/// only that line is generated again. Also auditions a line (not saved to History) and round-trips the text export.
/// Part of `--produce-headless`.
@MainActor
enum ConversationsHeadless {
    static let labeled = """
    Title: Night Ferry

    Ada: Is this the last ferry tonight?
    Ben: It is. After this one the harbor closes until morning.
    Ada: Then I suppose I'm staying on the island. [pause 0.8s]
    Cleo: You could stay with us. The spare room has a view of the lighthouse.
    Ben: She snores, though. Fair warning.
    Cleo: I do not.
    """

    static func run(_ h: ProduceHeadless.Harness) async -> Bool {
        let log = ProduceHeadless.log
        log("== Conversations ==")
        ConversationsModel.silentAuditions = true
        let model = ConversationsModel(service: h.service, settings: h.settings, voices: h.voices, pronunciations: h.pronunciations,
                                       shelf: h.shelf, drafts: nil)
        await model.prepare()
        guard let speakers = ProofModels.speakers(h.catalog) else { log("FAIL no model with preset voices"); return false }
        model.choice = ProofModels.choice(speakers, shelf: h.shelf)
        var ok = true

        // 1. A labeled .txt script.
        let txt = h.media.appendingPathComponent("Night Ferry.txt")
        try? labeled.write(to: txt, atomically: true, encoding: .utf8)
        do { try model.importScript(from: txt) } catch { log("FAIL importing txt: \(error)"); return false }
        report(model)
        ok = ProduceHeadless.check(model.importReport?.layout == .labeled && model.speakers.count == 3 && model.lines.count == 6,
                                   ".txt: labeled layout, 3 speakers, 6 lines") && ok
        ok = ProduceHeadless.check(model.lines[2].pauseAfter == 0.8, ".txt: trailing [pause 0.8s] became that line's pause") && ok
        ok = ProduceHeadless.check(Set(model.speakers.map(\.voice)).count == 3, "each speaker got a distinct voice") && ok
        ok = await renderTwice(model, h: h, label: "txt") && ok

        // Audition one line on its own: heard, not saved.
        let before = (try? await h.history.count()) ?? -1
        model.setText("Fine. But only for one night. [pause 0.3s] Maybe two.", for: model.lines[2].id)
        let auditioned = model.lines[2].id
        log("audition line 3 (\(model.lines[2].text))")
        model.audition(auditioned)
        await ProduceHeadless.watch(model.auditionRunner, label: "audition")
        for _ in 0..<100 where model.auditionURL == nil { try? await Task.sleep(for: .milliseconds(30)) }
        let after = (try? await h.history.count()) ?? -2
        var auditionSeconds: Double?
        if let u = model.auditionURL { auditionSeconds = try? await AudioReader.probe(u).duration }
        ok = ProduceHeadless.check(model.auditionURL != nil && after == before,
                                   "audition: \(String(format: "%.2f", auditionSeconds ?? 0)) s in a temporary file, History unchanged (\(before) → \(after))") && ok
        ok = ProduceHeadless.check(model.isRendered(model.lines[2]) && model.pendingLines == 0,
                                   "the auditioned line now counts as rendered: \(model.pendingLines) line(s) pending") && ok
        let t0 = Date()
        model.render()
        await ProduceHeadless.watch(model.runner, label: "after audition")
        log("re-render after the audition: \(String(format: "%.2f", Date().timeIntervalSince(t0))) s, reused \(model.result?.reused ?? -1) of \(model.result?.lines ?? -1)")
        ok = ProduceHeadless.check(model.result?.reused == model.spokenLines.count, "every line reused, the auditioned one included") && ok

        // Text export round trip.
        let exported = model.exportText
        let back = ConversationImporter.parse(exported).script
        ok = ProduceHeadless.check(back.lines.count == model.lines.count && back.lines.map(\.text) == model.lines.map(\.text)
                                   && back.lines.map(\.pauseAfter) == model.lines.map(\.pauseAfter),
                                   "export → import round-trips lines, text and pauses") && ok

        // A script without speaker names asks first: nothing changes until the user picks one voice or alternating.
        let prose = h.media.appendingPathComponent("Ferry, draft 2.txt")
        try? ConversationsFixtures.paragraphs.write(to: prose, atomically: true, encoding: .utf8)
        let scriptBefore = model.script
        do { try model.importScript(from: prose) } catch { log("FAIL importing prose: \(error)"); return false }
        ok = ProduceHeadless.check(model.pendingUnnamedImport?.paragraphs == 4 && model.script == scriptBefore,
                                   "no speaker names: the import asks, the working script is untouched") && ok
        model.cancelUnnamedImport()
        ok = ProduceHeadless.check(model.pendingUnnamedImport == nil && model.script == scriptBefore, "dismissing the question keeps the script") && ok
        try? model.importScript(from: prose)
        model.finishUnnamedImport(.oneVoice)
        ok = ProduceHeadless.check(model.speakers.map(\.name) == ["Narrator"] && model.lines.count == 4, "one voice: every paragraph read by one speaker") && ok
        try? model.importScript(from: prose)
        model.finishUnnamedImport(.alternating)
        ok = ProduceHeadless.check(model.speakers.count == 2 && model.lines.count == 4
                                   && model.lines.map(\.speakerID) == [0, 1, 0, 1].map { model.speakers[$0].id },
                                   "alternating: paragraphs alternate between two speakers") && ok

        // 2. A screenplay, printed to PDF.
        let pdf = h.media.appendingPathComponent("The Lighthouse Keeper.pdf")
        do { try printPDF(ConversationsFixtures.screenplay, to: pdf) } catch { log("FAIL writing the PDF: \(error)"); return false }
        log("wrote \(pdf.lastPathComponent) (\((try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0) bytes)")
        do { try model.importScript(from: pdf) } catch { log("FAIL importing pdf: \(error)"); return false }
        report(model)
        ok = ProduceHeadless.check(model.importReport?.layout == .screenplay && model.speakers.count == 3,
                                   ".pdf: screenplay layout, cast of three (\(model.speakers.map(\.name).joined(separator: ", ")))") && ok
        ok = ProduceHeadless.check(model.canUndoImport, "the import can be undone (it replaced a script)") && ok
        ok = await renderTwice(model, h: h, label: "pdf") && ok
        return ok
    }

    private static func report(_ model: ConversationsModel) {
        guard let r = model.importReport else { return }
        ProduceHeadless.log("imported \(r.fileName): layout \(r.layout.rawValue), \(r.speakers) speakers, \(r.lines) lines; notes: \(r.notes.isEmpty ? "none" : r.notes.joined(separator: " "))")
        for s in model.speakers {
            ProduceHeadless.log("  cast: \(s.name) → \(s.voice)")
        }
        for (i, l) in model.lines.enumerated() {
            ProduceHeadless.log("  \(i + 1). \(model.speaker(l.speakerID)?.name ?? "?"): \(l.text)" + (l.pauseAfter.map { "  [pause after \($0) s]" } ?? ""))
        }
    }

    /// Renders, edits one line, renders again: the second render generates one line and reuses the rest.
    private static func renderTwice(_ model: ConversationsModel, h: ProduceHeadless.Harness, label: String) async -> Bool {
        let log = ProduceHeadless.log
        var ok = true
        if let reason = model.blockedReason { log("FAIL [\(label)] blocked: \(reason)"); return false }
        log("[\(label)] render() — \(model.idleNote ?? "")")
        var linesSeen: [Int] = []
        let t1 = Date()
        var generated1: TimeInterval?
        model.render()
        await ProduceHeadless.watch(model.runner, label: label) { stage in
            if let i = model.renderingIndex, i < model.spokenLines.count, linesSeen.last != i { linesSeen.append(i) }
            if generated1 == nil, stage.hasPrefix("Normal") || stage.hasPrefix("Saving") { generated1 = Date().timeIntervalSince(t1) }
        }
        let first = Date().timeIntervalSince(t1)
        guard let r1 = model.result, case .finished? = model.runner.lastOutcome else {
            log("FAIL [\(label)] first render: \(model.runner.error.map { "\($0)" } ?? "no result")"); return false
        }
        log("[\(label)] first render: \(String(format: "%.2f", first)) s → \(String(format: "%.2f", r1.record.duration)) s of audio, generated \(r1.lines - r1.reused), reused \(r1.reused); lines lit in turn: \(linesSeen.map { $0 + 1 }); lines ready after \(String(format: "%.2f", generated1 ?? -1)) s (the rest is post-processing)")
        ok = ProduceHeadless.check(linesSeen.count == model.spokenLines.count || r1.reused > 0, "[\(label)] progress went line by line") && ok

        // Edit one line, change a pause (pauses never need generating).
        let edited = model.lines[min(1, model.lines.count - 1)]
        model.setText(edited.text + " Honestly.", for: edited.id)
        model.setPause(1.0, after: model.lines[0].id)
        log("[\(label)] edited line 2 and the pause after line 1: \(model.pendingLines) line(s) pending — \(model.idleNote ?? "")")
        ok = ProduceHeadless.check(model.pendingLines == 1, "[\(label)] only the edited line is pending") && ok
        let t2 = Date()
        var generated2: TimeInterval?
        model.render()
        await ProduceHeadless.watch(model.runner, label: label) { stage in
            if generated2 == nil, stage.hasPrefix("Normal") || stage.hasPrefix("Saving") { generated2 = Date().timeIntervalSince(t2) }
        }
        let second = Date().timeIntervalSince(t2)
        guard let r2 = model.result, r2.record.id != r1.record.id else { log("FAIL [\(label)] second render"); return false }
        log("[\(label)] second render: \(String(format: "%.2f", second)) s (first was \(String(format: "%.2f", first)) s) → \(String(format: "%.2f", r2.record.duration)) s, generated \(r2.lines - r2.reused), reused \(r2.reused); lines ready after \(String(format: "%.2f", generated2 ?? -1)) s (first: \(String(format: "%.2f", generated1 ?? -1)) s)")
        ok = ProduceHeadless.check(r2.reused == model.spokenLines.count - 1, "[\(label)] the re-render reused every unchanged line") && ok
        ok = ProduceHeadless.check(r2.record.duration > r1.record.duration, "[\(label)] longer after adding words and a longer pause") && ok
        let heard = await h.hear(r2.record.audioURL)
        let script = model.spokenLines.map(\.text).joined(separator: " ")
        let overlap = ProduceHeadless.overlap(script.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression), heard)
        log("[\(label)] heard back: “\(heard)”")
        ok = ProduceHeadless.check(overlap >= 0.8, "[\(label)] the conversation says the script (\(Int(overlap * 100))% of words)") && ok
        return ok
    }

    /// Prints text into a US Letter PDF in Courier, the way screenplays are laid out.
    static func printPDF(_ text: String, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        let font = CTFontCreateWithName("Courier" as CFString, 12, nil)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black.cgColor])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var start = 0
        while start < attributed.length {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: start, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            let visible = CTFrameGetVisibleStringRange(frame)
            ctx.endPDFPage()
            guard visible.length > 0 else { break }
            start += visible.length
        }
        ctx.closePDF()
    }
}
#endif
