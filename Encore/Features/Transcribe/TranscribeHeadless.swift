#if DEBUG
import EncoreCore
import Foundation

/// The Transcribe screen's own model (`TranscribeModel` + its `JobRunner`) transcribing real media: a synthesized
/// clip and a small video made from it with ffmpeg, with segment and with word timings; then the exports, SRT
/// written to disk. Part of `--produce-headless`.
@MainActor
enum TranscribeHeadless {
    static let script = "Places, everyone. The lights come up slowly on the harbor. Mira waits on the dock, and the radio crackles. " +
        "Tom enters on the second bell, not the first. Let the silence sit, and the audience will lean in."

    static func run(_ h: ProduceHeadless.Harness) async -> Bool {
        let log = ProduceHeadless.log
        log("== Transcribe ==")
        let clip: URL
        do { clip = try await h.speak(script.replacingOccurrences(of: ". ", with: ". [pause 0.7s] "), voice: "bm_george", name: "rehearsal.wav") }
        catch { log("FAIL synthesizing: \(error)"); return false }
        // A small video: a black frame with the clip as its soundtrack.
        let video = h.media.appendingPathComponent("rehearsal.mp4")
        guard let ffmpeg = FFmpeg.locate() else { log("FAIL ffmpeg not found"); return false }
        let p = Process()
        p.executableURL = ffmpeg
        p.arguments = ["-v", "error", "-y", "-f", "lavfi", "-i", "color=c=black:s=320x240:r=24", "-i", clip.path,
                       "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", video.path]
        do { try p.run(); p.waitUntilExit() } catch { log("FAIL ffmpeg: \(error)"); return false }
        let vinfo = try? await AudioReader.probe(video)
        log("video: \(video.lastPathComponent), \(String(format: "%.2f", vinfo?.duration ?? 0)) s, hasVideo \(vinfo?.hasVideo ?? false), decoder \(vinfo?.decoder.rawValue ?? "-")")

        let model = TranscribeModel(service: h.service, settings: h.settings, shelf: h.shelf, drafts: nil)
        await model.prepare()
        guard let whisper = h.catalog.model("whisper-large-v3-turbo") else { log("FAIL no whisper manifest"); return false }
        var ok = true

        ok = await transcribe(model, h: h, media: clip, model: whisper, timestamps: .segment, label: "clip/segments") && ok
        if let r = model.record {
            log("coarse-segments hint shown: \(model.hasCoarseSegments)")
            // Exports from the record on screen; SRT written to disk as the save panel would.
            let srt = model.text(as: .srt)
            let srtURL = h.media.appendingPathComponent("rehearsal.srt")
            try? srt.write(to: srtURL, atomically: true, encoding: .utf8)
            log("SRT (\(srtURL.lastPathComponent), \(srt.count) chars):\n" + srt.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n"))
            let vtt = model.text(as: .vtt)
            let json = model.text(as: .json)
            ok = ProduceHeadless.check(srt.hasPrefix("1\n00:00:") && srt.contains(" --> "), "SRT has numbered, timed cues") && ok
            ok = ProduceHeadless.check(vtt.hasPrefix("WEBVTT"), "WebVTT starts with its header") && ok
            ok = ProduceHeadless.check((try? JSONDecoder().decode(Transcript.self, from: Data(json.utf8))) == r.transcript, "JSON decodes back to the same transcript") && ok
            log("timestamped text:\n" + model.text(as: .timestampedText).split(separator: "\n").prefix(4).joined(separator: "\n"))
            // Timings toggle is display only.
            let id = r.id
            model.showTimings = false
            ok = ProduceHeadless.check(model.record?.id == id && !model.runner.isBusy, "hiding timings re-runs nothing") && ok
            model.showTimings = true
            // A segment's index from the playhead.
            if r.transcript.segments.count > 1 {
                let s = r.transcript.segments[1]
                let i = TranscribeModel.segmentIndex(at: (s.start + s.end) / 2, in: r.transcript.segments)
                ok = ProduceHeadless.check(i == 1, "the playhead in segment 2 finds segment 2") && ok
            }
        }
        ok = await transcribe(model, h: h, media: clip, model: whisper, timestamps: .word, label: "clip/words") && ok
        if let words = model.record?.transcript.segments.flatMap({ $0.words ?? [] }) {
            log("first words: " + words.prefix(8).map { String(format: "%@ %.2f–%.2f", $0.text.trimmingCharacters(in: .whitespaces), $0.start, $0.end) }.joined(separator: " | "))
            let srt = model.text(as: .srt)
            log("SRT with word timings, first cues:\n" + srt.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n"))
        }
        ok = await transcribe(model, h: h, media: video, model: whisper, timestamps: .segment, label: "video/segments") && ok
        ok = await transcribe(model, h: h, media: video, model: whisper, timestamps: .word, label: "video/words") && ok
        try? await Task.sleep(for: .milliseconds(300))
        ok = ProduceHeadless.check(model.recentTotal == 4, "all four are in the screen's earlier list (\(model.recentTotal))") && ok
        return ok
    }

    private static func transcribe(_ model: TranscribeModel, h: ProduceHeadless.Harness, media: URL, model m: ModelManifest,
                                   timestamps: TimestampGranularity, label: String) async -> Bool {
        let log = ProduceHeadless.log
        model.closeTranscript()
        model.setSource(media)
        model.debugSet(choice: ModelChoice(modelID: m.id, variantID: h.shelf.preferredVariant(m).id), timestamps: timestamps)
        await model.waitForSource()
        if timestamps == .word { await h.shelf.refreshRuntimes(for: [m], requiring: .wordTimestamps) }
        log("[\(label)] runtime for \(timestamps.rawValue) timings: \(model.plannedRuntime.map { "\($0)" } ?? "(not asked: segments run wherever the model does)")")
        if let reason = model.blockedReason { log("FAIL [\(label)] blocked: \(reason)"); return false }
        model.transcribe()
        await ProduceHeadless.watch(model.runner, label: label)
        guard case .finished(let elapsed)? = model.runner.lastOutcome, let r = model.record else {
            log("FAIL [\(label)] \(model.runner.error.map { "\($0)" } ?? "no record")"); return false
        }
        let t = r.transcript
        let words = t.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
        log("[\(label)] \(String(format: "%.1f", elapsed)) s: language \(t.language ?? "-"), \(t.segments.count) segments, \(words) timed words, duration \(String(format: "%.2f", t.duration ?? 0)) s")
        for s in t.segments.prefix(6) { log(String(format: "    [%6.2f – %6.2f] %@", s.start, s.end, s.text.trimmingCharacters(in: .whitespaces))) }
        let overlap = ProduceHeadless.overlap(script, t.text)
        var ok = ProduceHeadless.check(overlap >= 0.85, "[\(label)] \(Int(overlap * 100))% of the script's words recognized") && timingsOK(t, timestamps)
        ok = ProduceHeadless.check(model.recordTrack != nil, "[\(label)] the transcript's player has the media") && ok
        return ok
    }

    private static func timingsOK(_ t: Transcript, _ g: TimestampGranularity) -> Bool {
        switch g {
        case .none: return true
        case .segment:
            let blocks = t.segments.count == 1 && (t.segments[0].end - t.segments[0].start) > 12
            return ProduceHeadless.check(!t.segments.isEmpty && zip(t.segments, t.segments.dropFirst()).allSatisfy { $0.start <= $1.start }
                                         && abs((t.segments.last?.end ?? 0) - (t.duration ?? 0)) < 1.5,
                                         "\(t.segments.count) segment(s), timed, in order, covering the audio"
                                         + (blocks ? " (one block per 30 s window: the coarse-segments hint shows on screen)" : ""))
        case .word:
            let words = t.segments.flatMap { $0.words ?? [] }
            return ProduceHeadless.check(words.count >= 30 && zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start + 0.01 },
                                         "\(words.count) words timed, in order")
        }
    }
}
#endif
