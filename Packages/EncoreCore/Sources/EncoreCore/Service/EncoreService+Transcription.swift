import Foundation

extension EncoreService {
    /// Speech to text from any audio or video file: decode to 16 kHz mono WAV, transcribe, save to history.
    public func transcribe(_ request: TranscriptionRequest) -> AsyncThrowingStream<TranscriptionEvent, Error> {
        stream { continuation in
            let started = Date()
            let manifest = try self.manifest(request.modelID, for: .stt)
            let source = URL(fileURLWithPath: (request.mediaPath as NSString).expandingTildeInPath)
            try Self.checkReadable(source)
            let context = try self.loadContext(manifest, variantID: request.variantID)
            let needs: EngineFeatures = request.timestamps == .word ? [.transcription, .wordTimestamps] : .transcription
            let candidates = try await self.capableBackends(for: manifest, needs: needs)

            let record = try await self.runtime.run(.transcription, title: source.lastPathComponent, model: manifest) { job in
                let report = Reporter(job: job, continuation: continuation, stageEvent: { .stage($0) },
                                      progressEvent: { .progress($0) })
                let temp = TempFiles(in: self.scratchDirectory)
                defer { temp.cleanup() }
                await report.stage("Preparing audio")
                let wav = try await self.prepare(source, range: nil, temp: temp, report: report, progress: 0...0.1)
                let session = EngineSession(candidates: candidates, context: context, job: job,
                                            feature: needs.contains(.wordTimestamps) ? .wordTimestamps : .transcription) { await report.stage($0) }
                let sttJob = TranscriptionJob(modelID: manifest.id, audio: wav.url, language: request.language,
                                              timestamps: request.timestamps, parameters: request.parameters)
                var transcript = try await session.run { backend in
                    await report.stage("Transcribing")
                    return try await backend.transcribe(sttJob, progress: report.engineProgress(0.1...0.97))
                }
                if transcript.duration == nil { transcript.duration = wav.duration }
                await report.stage("Saving")
                try Task.checkCancellation()
                let record = TranscriptionRecord(sourceName: source.lastPathComponent, sourcePath: source.path, modelID: manifest.id,
                                                 modelName: manifest.name, transcript: transcript,
                                                 elapsed: Date().timeIntervalSince(started))
                try await self.history.insert(record)
                return record
            }
            await self.noteUsed(manifest.id, for: .transcription)
            continuation.yield(.progress(1))
            continuation.yield(.finished(record))
        }
    }

    /// Transcribes a voice-cloning reference clip (optionally just `range` of it) so the user doesn't have to type
    /// it. Nothing is saved to history. Uses `modelID`, else the last transcription model used, else the best
    /// downloaded one.
    public func transcribeReference(_ url: URL, range: ClosedRange<TimeInterval>? = nil, language: String? = nil,
                                    modelID: String? = nil) async throws -> Transcript {
        do {
            try Self.checkReadable(url)
            let manifest = try modelID.map { try self.manifest($0, for: .stt) } ?? defaultTranscriptionModel()
            return try await runtime.run(.referenceTranscription, title: url.lastPathComponent, model: manifest) { job in
                let temp = TempFiles(in: self.scratchDirectory)
                defer { temp.cleanup() }
                let wav = try await AudioPreparation.transcriptionWAV(from: url, to: temp.url("clip.wav"), range: range)
                guard let t = try await self.transcribeClip(wav, language: language, job: job, temp: temp, model: manifest) else {
                    throw ServiceError.noTranscriptionModel
                }
                return t
            }
        } catch {
            throw Self.publicError(error)
        }
    }

    /// The transcription model to use when the user didn't pick one.
    public func defaultTranscriptionModel() throws -> ModelManifest {
        let downloaded = catalog.models(for: .stt).filter { isDownloaded($0) }
        if let last = settings.snapshot().lastUsedModels[.transcription], let m = downloaded.first(where: { $0.id == last }) { return m }
        for id in ["whisper-large-v3-turbo", "parakeet-tdt-v3", "parakeet-tdt-v2", "whisper-large-v3"] {
            if let m = downloaded.first(where: { $0.id == id }) { return m }
        }
        guard let any = downloaded.first else { throw ServiceError.noTranscriptionModel }
        return any
    }

    /// Transcribes a short clip inside an already-running job (nil when no transcription model is downloaded).
    func transcribeClip(_ url: URL, language: String?, job: RuntimeJob, temp: TempFiles,
                        model: ModelManifest? = nil) async throws -> Transcript? {
        guard let manifest = try? model ?? defaultTranscriptionModel() else { return nil }
        let context = try loadContext(manifest, variantID: nil)
        let candidates = try await capableBackends(for: manifest, needs: .transcription)
        let wav = url.pathExtension.lowercased() == "wav" ? url
            : try await AudioPreparation.transcriptionWAV(from: url, to: temp.url("clip-\(UUID().uuidString).wav"))
        let session = EngineSession(candidates: candidates, context: context, job: job, feature: .transcription) { await job.stage($0) }
        let sttJob = TranscriptionJob(modelID: manifest.id, audio: wav, language: language, timestamps: .none)
        await job.stage("Transcribing reference")
        let t = try await session.run { try await $0.transcribe(sttJob, progress: nil) }
        return Transcript(text: t.text.trimmed(), language: t.language, duration: t.duration, segments: t.segments)
    }

    struct PreparedAudio { var url: URL; var duration: TimeInterval }

    /// Any media → 16 kHz mono WAV in the request's temp folder.
    func prepare<E>(_ source: URL, range: ClosedRange<TimeInterval>?, temp: TempFiles, report: Reporter<E>,
                    progress: ClosedRange<Double>) async throws -> PreparedAudio {
        let out = temp.url("input.wav")
        let callback = report.engineProgress(progress)
        do {
            _ = try await AudioPreparation.transcriptionWAV(from: source, to: out, range: range, progress: callback)
        } catch let e as AudioError {
            throw ServiceError.sourceUnreadable(path: source.path, reason: e.localizedDescription)
        }
        let duration = (try? await AudioReader.probe(out).duration) ?? 0
        return PreparedAudio(url: out, duration: duration)
    }

    static func checkReadable(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw ServiceError.sourceUnreadable(path: url.path, reason: "The file doesn't exist.")
        }
    }
}
