#if DEBUG
import EncoreCore
import Foundation

/// The Changer's own model (`ChangerModel` + its `JobRunner`) converting real recordings with the real Python helper:
/// a short clip, then a long one cut into several pieces. Checks duration, the words (transcribed back) and that the
/// voice moved toward the target (median pitch). Part of `--produce-headless`.
@MainActor
enum ChangerHeadless {
    static func run(_ h: ProduceHeadless.Harness) async -> Bool {
        let log = ProduceHeadless.log
        log("== Changer ==")
        let sourceText = "The harbor lights came on one by one, and the old keeper climbed the stairs to start his long night."
        let targetText = "Good evening. This is my voice, recorded clearly, so the changer can learn exactly how I sound."
        let source: URL, target: URL
        do {
            source = try await h.speak(sourceText, voice: "af_heart", name: "source-short.wav")
            target = try await h.speak(targetText, voice: "am_onyx", name: "target-voice.wav", speed: 0.95)
        } catch { log("FAIL synthesizing test audio: \(error)"); return false }
        let voice: Voice
        do {
            let d = try await AudioReader.probe(target).duration
            voice = try await h.voices.add(Voice(name: "Onyx", origin: .imported, transcript: targetText, language: "en", duration: d),
                                           referenceAudio: target)
        } catch { log("FAIL adding the target voice: \(error)"); return false }

        let model = ChangerModel(service: h.service, settings: h.settings, voices: h.voices, shelf: h.shelf, drafts: nil)
        await model.prepare()
        guard let vc = h.catalog.model("chatterbox-vc") else { log("FAIL no chatterbox-vc manifest"); return false }
        model.debugSet(choice: ModelChoice(modelID: vc.id, variantID: h.shelf.preferredVariant(vc).id), voiceID: voice.id)
        log("helper problem: \(model.helperProblem ?? "none"); downloaded: \(model.isDownloaded)")

        var ok = true
        ok = await convert(model, h: h, source: source, text: sourceText, target: target, label: "short") && ok

        // A longer recording, cut into several pieces.
        let paragraphs = [
            "Chapter one. It was raining in the way it only rains in port towns, sideways and without apology.",
            "Mira stood at the end of the dock with her coat pulled tight, watching the lamp swing above the water.",
            "Eleven years had passed since the ferry left, and every winter she had told herself it would be the last.",
            "Somewhere behind her a radio crackled, and a calm voice read out the shipping forecast for the night.",
            "When the footsteps finally came, they were slower than she remembered, but she knew them all the same.",
        ]
        let long: URL
        do { long = try await h.speak(paragraphs.joined(separator: " [pause 0.8s] "), voice: "bf_emma", name: "source-long.wav") }
        catch { log("FAIL synthesizing the long source: \(error)"); return false }
        model.pieceSeconds = 10
        ok = await convert(model, h: h, source: long, text: paragraphs.joined(separator: " "), target: target, label: "long") && ok

        // Flip the comparison mid-way: the other side must pick up at the same moment.
        if let r = model.result, r.original != nil {
            r.track.seek(to: 3.25)
            model.switchSide(to: .original)
            ok = ProduceHeadless.check(abs((r.original?.currentTime ?? 0) - 3.25) < 0.01 && model.side == .original,
                                       "comparison: switching to the original keeps the position (\(String(format: "%.2f", r.original?.currentTime ?? -1)) s)") && ok
        }
        let count = (try? await h.history.count(HistoryQuery(kinds: [.voiceChange]))) ?? -1
        ok = ProduceHeadless.check(count == 2 && model.recentTotal == 2, "history has both conversions (\(count)); recent list shows \(model.recentTotal)") && ok
        return ok
    }

    private static func convert(_ model: ChangerModel, h: ProduceHeadless.Harness, source: URL, text: String, target: URL, label: String) async -> Bool {
        let log = ProduceHeadless.log
        model.setSource(source)
        await model.waitForSource()
        let pieces = model.source?.pieces ?? []
        let duration = model.source?.info?.duration ?? 0
        log("[\(label)] source \(source.lastPathComponent): \(String(format: "%.2f", duration)) s, \(pieces.count) piece(s) " +
            pieces.map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: ", "))
        if let reason = model.blockedReason { log("FAIL blocked: \(reason)"); return false }
        log("[\(label)] convert() — \(model.idleNote ?? "")")
        var activePieces: [Int] = []
        model.convert()
        await ProduceHeadless.watch(model.runner, label: label) { _ in
            if let a = model.activePiece, activePieces.last != a { activePieces.append(a) }
        }
        guard case .finished(let elapsed)? = model.runner.lastOutcome, let result = model.result else {
            log("FAIL [\(label)] outcome \(String(describing: model.runner.lastOutcome)); error: \(model.runner.error.map { "\($0)" } ?? "none")")
            return false
        }
        let r = result.record
        log("[\(label)] finished in \(String(format: "%.1f", elapsed)) s: \(r.title), voice \(r.voiceName ?? "-"), \(String(format: "%.2f", r.duration)) s @ \(Int(r.sampleRate)) Hz")
        log("[\(label)] pieces seen lit while converting: \(activePieces)")
        let heard = await h.hear(r.audioURL)
        let overlap = ProduceHeadless.overlap(text, heard)
        let p0 = await ProduceHeadless.medianPitch(source), p1 = await ProduceHeadless.medianPitch(r.audioURL), pt = await ProduceHeadless.medianPitch(target)
        log("[\(label)] heard back: “\(heard)”")
        log("[\(label)] median pitch: source \(fmt(p0)) Hz, converted \(fmt(p1)) Hz, target voice \(fmt(pt)) Hz")
        var ok = true
        ok = ProduceHeadless.check(abs(r.duration - duration) < max(0.25, duration * 0.02),
                                   "[\(label)] duration preserved: \(String(format: "%.2f", duration)) → \(String(format: "%.2f", r.duration)) s") && ok
        ok = ProduceHeadless.check(overlap >= 0.8, "[\(label)] the words survive: \(Int(overlap * 100))% of the source's words heard back") && ok
        if let p0, let p1, let pt {
            ok = ProduceHeadless.check(abs(p1 - pt) < abs(p0 - pt), "[\(label)] the voice moved toward the target") && ok
        }
        if pieces.count > 1 {
            ok = ProduceHeadless.check(activePieces.count >= min(3, pieces.count), "[\(label)] piece progress followed the service (\(activePieces.count) steps for \(pieces.count) pieces)") && ok
        }
        ok = ProduceHeadless.check(result.original?.url == source, "[\(label)] comparison has the original") && ok
        return ok
    }

    private static func fmt(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
}
#endif
