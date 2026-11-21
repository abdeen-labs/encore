import EncoreCore
import Foundation
import MLXAudioCore
import MLXAudioSTT
import MLXAudioTTS

/// Runs models in-process with MLX Swift.
public final class MLXSwiftBackend: EngineBackend, @unchecked Sendable {
    public let runtime: EngineRuntime = .mlxSwift
    public init() {}

    public func engineFeatures() async -> [String: EngineFeatures] { [:] }
    public func availability() async -> BackendAvailability { .ready }
    public func load(_ context: ModelLoadContext) async throws {
        throw EngineError.unsupported("MLX Swift engines are not implemented yet.")
    }
    public func unload(modelID: String) async {}
    public func loadedModelIDs() async -> [String] { [] }
    public func synthesize(_ job: SynthesisJob, progress: EngineProgress?) async throws -> AudioBuffer {
        throw EngineError.modelNotLoaded(job.modelID)
    }
    public func transcribe(_ job: TranscriptionJob, progress: EngineProgress?) async throws -> Transcript {
        throw EngineError.modelNotLoaded(job.modelID)
    }
    public func convertVoice(_ job: VoiceConversionJob, progress: EngineProgress?) async throws -> AudioBuffer {
        throw EngineError.unsupported("Voice conversion runs in the Python helper.")
    }
}
