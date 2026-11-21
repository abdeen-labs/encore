import Foundation

extension EncoreService {
    /// Voice design: `candidates` clips of `sampleText` from a description, each a different voice, emitted as each
    /// finishes. Candidate files live in the scratch folder until saved (`saveDesignedVoice`) or discarded; a
    /// cancelled run deletes the ones it made. With a `seed` parameter, candidate i uses seed + i (reproducible).
    public func designVoice(_ request: VoiceDesignRequest) -> AsyncThrowingStream<VoiceDesignEvent, Error> {
        stream { continuation in
            let manifest = try self.manifest(request.modelID, for: .tts)
            guard manifest.capabilities.voiceDesign else {
                throw ServiceError.featureUnsupported(modelID: manifest.id, modelName: manifest.name, feature: .voiceDesign,
                                                      detail: "Pick a model that designs voices, such as Qwen3-TTS VoiceDesign.")
            }
            let description = request.description.trimmed()
            let sample = request.sampleText.trimmed()
            guard !description.isEmpty else { throw ServiceError.invalidRequest("Describe the voice first.") }
            guard !sample.isEmpty else { throw ServiceError.invalidRequest("Give the candidates something to say.") }
            let count = min(8, max(1, request.candidates))
            let context = try self.loadContext(manifest, variantID: request.variantID)
            let candidates = try await self.capableBackends(for: manifest, needs: [.synthesis, .voiceDesign])
            let folder = self.designDirectory

            try await self.runtime.run(.voiceDesign, title: Self.title(from: description, fallback: "Voice design"), model: manifest) { job in
                let report = Reporter(job: job, continuation: continuation, stageEvent: { .stage($0) }, progressEvent: { .progress($0) })
                let session = EngineSession(candidates: candidates, context: context, job: job, feature: .voiceDesign) { await report.stage($0) }
                var made: [URL] = []
                do {
                    for i in 0..<count {
                        try Task.checkCancellation()
                        var parameters = request.parameters
                        var seed: Int?
                        if let base = request.parameters["seed"]?.intValue { seed = base + i; parameters["seed"] = .int(base + i) }
                        let synth = SynthesisJob(modelID: manifest.id, text: sample, voice: nil, instruct: description,
                                                 language: request.language, parameters: parameters)
                        let lo = Double(i) / Double(count), hi = Double(i + 1) / Double(count)
                        let audio = try await session.run { backend in
                            await report.stage(count > 1 ? "Designing voice \(i + 1) of \(count)" : "Designing voice")
                            return try await backend.synthesize(synth, progress: report.engineProgress(lo...hi))
                        }
                        try Task.checkCancellation()
                        var post = PostProcessingOptions()
                        post.removeSilence = true
                        post.maxSilenceSeconds = 0.5
                        let clip = PostProcessor.apply(post, to: audio)
                        let id = UUID()
                        let url = folder.appendingPathComponent("\(id.uuidString).wav")
                        made.append(url)
                        try AudioExporter.writeWAV(clip, to: url, encoding: .pcm24)
                        continuation.yield(.candidate(VoiceDesignCandidate(id: id, audioPath: url.path, transcript: sample,
                                                                           description: description, modelID: manifest.id,
                                                                           duration: clip.duration, seed: seed)))
                        await report.progress(hi)
                    }
                } catch {
                    made.forEach { try? FileManager.default.removeItem(at: $0) }
                    throw error
                }
            }
            await self.noteUsed(manifest.id, for: .voiceDesign)
            continuation.yield(.progress(1))
            continuation.yield(.finished)
        }
    }

    /// Saves a design candidate to the voice library. Its clip and exact transcript become the cloning reference and
    /// the description is kept as `designPrompt`. The candidate's file stays until discarded, so others can be saved too.
    @discardableResult
    public func saveDesignedVoice(_ candidate: VoiceDesignCandidate, name: String, tags: [String] = [],
                                  language: String? = nil, notes: String = "") async throws -> Voice {
        let url = URL(fileURLWithPath: candidate.audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ServiceError.voiceMissing("The candidate's clip") }
        let trimmedName = name.trimmed()
        guard !trimmedName.isEmpty else { throw ServiceError.invalidRequest("Name the voice first.") }
        let voice = Voice(name: trimmedName, tags: tags, origin: .designed, transcript: candidate.transcript, language: language,
                          notes: notes, designPrompt: candidate.description, sourceModelID: candidate.modelID,
                          duration: candidate.duration)
        return try await voices.add(voice, referenceAudio: url, move: false)
    }

    /// Deletes candidate clips the user didn't keep.
    public func discardDesignCandidates(_ candidates: [VoiceDesignCandidate]) {
        for c in candidates {
            let url = URL(fileURLWithPath: c.audioPath)
            // Only ever delete files in our own folder.
            guard url.deletingLastPathComponent().standardizedFileURL == designDirectory.standardizedFileURL else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    var designDirectory: URL {
        let url = scratchDirectory.appendingPathComponent("Design", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
