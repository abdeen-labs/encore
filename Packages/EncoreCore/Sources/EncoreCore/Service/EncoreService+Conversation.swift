import CryptoKit
import Foundation

extension EncoreService {
    /// A multi-speaker conversation: each line in its speaker's voice (pause and voice tags inside a line work as in
    /// speech), the conversation's pause between lines (or the line's own), one combined record.
    ///
    /// Lines are cached in memory by everything that shapes their audio (model, variant, text after pronunciations,
    /// voice, language, parameters), so re-rendering after editing one line only regenerates that line. Set
    /// `reuseRenderedLines` to false for fresh takes of every line.
    public func renderConversation(_ request: ConversationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        stream { continuation in
            let started = Date()
            let manifest = try self.manifest(request.modelID, for: .tts)
            let script = request.script
            let speakers = Dictionary(script.speakers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let lines = script.lines.filter { !$0.text.trimmed().isEmpty }
            guard !lines.isEmpty else { throw ServiceError.emptyScript }
            let library = await self.libraryVoices()
            let entries = self.pronunciations.enabledEntries()

            // Plan every line up front so problems surface before any work.
            var plannedLines: [(line: ConversationScript.Line, speaker: ConversationScript.Speaker, plan: ScriptPlan)] = []
            var selections: [VoiceSelection] = []
            for line in lines {
                guard let speaker = speakers[line.speakerID] else {
                    throw ServiceError.invalidRequest("A line belongs to a speaker who isn't in the conversation.")
                }
                var r = SpeechRequest(modelID: manifest.id, text: line.text)
                r.voice = speaker.voice
                r.applyPronunciations = request.applyPronunciations
                let plan = ScriptPlanner(request: r, manifest: manifest, library: library, pronunciations: entries).plan(line.text)
                try Self.check(plan)
                for s in Self.voiceSelections(in: plan, default: speaker.voice) where !selections.contains(s) { selections.append(s) }
                plannedLines.append((line, speaker, plan))
            }
            for s in selections { try self.validate(s, for: manifest) }
            let context = try self.loadContext(manifest, variantID: request.variantID)
            let needs = Self.speechNeeds(manifest, selections: selections, instruct: nil)
            let candidates = try await self.capableBackends(for: manifest, needs: needs)
            let title = script.title.trimmed().isEmpty ? "Conversation" : script.title.trimmed()
            let settings = SpeechSettings(modelID: manifest.id, instruct: nil, language: request.language, parameters: request.parameters)
            let planned = plannedLines

            let record = try await self.runtime.run(.conversation, title: title, model: manifest) { job in
                let report = Reporter(job: job, continuation: continuation, stageEvent: { .stage($0) }, progressEvent: { .progress($0) })
                let temp = TempFiles(in: self.scratchDirectory)
                defer { temp.cleanup() }
                let session = EngineSession(candidates: candidates, context: context, job: job,
                                            feature: needs.contains(.cloning) ? .cloning : .speech) { await report.stage($0) }
                let voices = VoiceResolver(service: self, manifest: manifest, job: job, temp: temp)
                var assembler = Assembler()
                var reused = 0
                for (i, item) in planned.enumerated() {
                    try Task.checkCancellation()
                    let lo = 0.9 * Double(i) / Double(planned.count), hi = 0.9 * Double(i + 1) / Double(planned.count)
                    let key = Self.cacheKey(item.plan, voice: item.speaker.voice, context: context, settings: settings, library: library)
                    var audio: AudioBuffer
                    if request.reuseRenderedLines, let cached = await self.lineCache.get(key) {
                        audio = cached
                        reused += 1
                    } else {
                        let n = planned.count
                        audio = try await self.render(item.plan, voice: item.speaker.voice, settings: settings, session: session,
                                                      voices: voices, report: report, progress: lo...hi) { c, total in
                            total > 1 ? "Line \(i + 1) of \(n) (\(item.speaker.name)), part \(c) of \(total)"
                                : "Line \(i + 1) of \(n) (\(item.speaker.name))"
                        }
                        await self.lineCache.put(key, audio)
                    }
                    try assembler.append(audio)
                    if i + 1 < planned.count { assembler.appendSilence(max(0, item.line.pauseAfter ?? request.pauseSeconds)) }
                    await report.progress(hi)
                }
                if reused > 0 { await report.stage("Reused \(reused) unchanged line\(reused == 1 ? "" : "s")") }
                let audio = try assembler.finish(defaultRate: Double(manifest.sampleRate))
                let processed = try await self.postProcess(audio, request.post, report: report)
                await report.stage("Saving")
                let names = script.speakers.filter { s in planned.contains { $0.speaker.id == s.id } }.map(\.name)
                return try await self.commit(processed) { url in
                    GenerationRecord(kind: .conversation, title: title, text: ConversationImporter.text(for: script),
                                     modelID: manifest.id, modelName: manifest.name, voiceName: names.joined(separator: ", "),
                                     parameters: manifest.defaultParameters.merging(request.parameters) { $1 },
                                     audioPath: url.path, duration: processed.duration, sampleRate: processed.sampleRate,
                                     elapsed: Date().timeIntervalSince(started))
                }
            }
            await self.noteUsed(manifest.id, for: .conversation)
            continuation.yield(.progress(1))
            continuation.yield(.finished(record))
        }
    }

    /// Forgets cached conversation lines.
    public func clearConversationCache() async { await lineCache.removeAll() }

    static func cacheKey(_ plan: ScriptPlan, voice: VoiceSelection, context: ModelLoadContext, settings: SpeechSettings,
                         library: [Voice]) -> String {
        var parts = [context.manifest.id, context.variant.id, settings.language ?? "", settings.instruct ?? ""]
        parts += settings.parameters.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.jsonObject)" }
        for item in plan.items {
            switch item {
            case .pause(let s, _): parts.append("pause:\(s)")
            case .speech(let c):
                let v = c.voice ?? voice
                var voiceKey = "\(v)"
                // A library voice's reference can be re-recorded or its transcript edited; key on both.
                if case .library(let id) = v, let voice = library.first(where: { $0.id == id }) {
                    voiceKey += "|\(voice.transcript)|\(voice.duration)"
                }
                parts.append("speech:\(c.text)|\(voiceKey)|\(c.gapAfter)")
            }
        }
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
