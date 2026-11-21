import Foundation

extension EncoreService {
    /// Speech to speech: reads any audio/video, cuts long recordings at pauses, converts each piece to the target
    /// voice, puts the pieces back on the original timeline, post-processes and records the result.
    public func convertVoice(_ request: VoiceConversionRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        stream { continuation in
            let started = Date()
            let manifest = try self.manifest(request.modelID, for: .voiceConversion)
            let source = URL(fileURLWithPath: (request.sourcePath as NSString).expandingTildeInPath)
            try Self.checkReadable(source)
            if case .automatic = request.voice { throw ServiceError.invalidRequest("Pick the voice to change to.") }
            try self.validate(request.voice, for: manifest)
            let context = try self.loadContext(manifest, variantID: request.variantID)
            let candidates = try await self.capableBackends(for: manifest, needs: .voiceConversion)
            let title = request.title ?? "Voice change · \(source.deletingPathExtension().lastPathComponent)"

            let record = try await self.runtime.run(.voiceConversion, title: title, model: manifest) { job in
                let report = Reporter(job: job, continuation: continuation, stageEvent: { .stage($0) }, progressEvent: { .progress($0) })
                let temp = TempFiles(in: self.scratchDirectory)
                defer { temp.cleanup() }
                await report.stage("Reading \(source.lastPathComponent)")
                let segments: [AudioSegment]
                do { segments = try await SpeechSegmenter.segment(fileAt: source, options: Self.conversionSegmentOptions(request)) }
                catch let e as AudioError { throw ServiceError.sourceUnreadable(path: source.path, reason: e.localizedDescription) }
                let session = EngineSession(candidates: candidates, context: context, job: job, feature: .voiceConversion) { await report.stage($0) }
                let target = try await VoiceResolver(service: self, manifest: manifest, job: job, temp: temp).resolve(request.voice)
                guard let voice = target.engine else { throw ServiceError.invalidRequest("Pick the voice to change to.") }

                var pieces: [(segment: AudioSegment, audio: AudioBuffer)] = []
                for (i, segment) in segments.enumerated() {
                    try Task.checkCancellation()
                    let piece = try await AudioPreparation.wav(from: source, to: temp.url("piece-\(i).wav"), range: segment.range)
                    let lo = 0.05 + 0.85 * Double(i) / Double(segments.count), hi = 0.05 + 0.85 * Double(i + 1) / Double(segments.count)
                    let vcJob = VoiceConversionJob(modelID: manifest.id, source: piece, target: voice,
                                                   parameters: request.parameters.filter { $0.key != "segment_seconds" })
                    let audio = try await session.run { backend in
                        await report.stage(segments.count > 1 ? "Converting \(i + 1) of \(segments.count)" : "Converting")
                        return try await backend.convertVoice(vcJob, progress: report.engineProgress(lo...hi))
                    }
                    try? FileManager.default.removeItem(at: piece)
                    pieces.append((segment, audio))
                    await report.progress(hi)
                }
                let rate = pieces.first { !$0.audio.isEmpty }?.audio.sampleRate ?? Double(manifest.sampleRate)
                let stitched = try SpeechSegmenter.stitch(pieces, sampleRate: rate)
                let processed = try await self.postProcess(stitched, request.post, report: report)
                await report.stage("Saving")
                return try await self.commit(processed) { url in
                    GenerationRecord(kind: .voiceChange, title: title, text: source.lastPathComponent, modelID: manifest.id,
                                     modelName: manifest.name, voiceName: target.name, voiceID: target.libraryID,
                                     parameters: manifest.defaultParameters.merging(request.parameters) { $1 },
                                     audioPath: url.path, duration: processed.duration, sampleRate: processed.sampleRate,
                                     elapsed: Date().timeIntervalSince(started))
                }
            }
            await self.noteUsed(manifest.id, for: .voiceChange)
            continuation.yield(.progress(1))
            continuation.yield(.finished(record))
        }
    }

    /// Pieces of at most 20 s by default; a `segment_seconds` parameter overrides it.
    static func conversionSegmentOptions(_ request: VoiceConversionRequest) -> SpeechSegmenter.Options {
        let max = request.parameters["segment_seconds"]?.doubleValue ?? 20
        return SpeechSegmenter.Options(maxDuration: Swift.max(4, max), minDuration: Swift.min(4, max / 2))
    }
}
