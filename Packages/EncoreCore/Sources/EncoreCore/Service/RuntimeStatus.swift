import Foundation
import Observation

extension EngineRuntime {
    /// What the UI calls each runtime.
    public var displayName: String {
        switch self {
        case .mlxSwift: "Native"
        case .python: "Python helper"
        }
    }
}

/// A model the governor holds in memory.
public struct LoadedModel: Codable, Sendable, Hashable, Identifiable {
    public var modelID: String
    public var modelName: String
    public var variantID: String
    public var variantLabel: String
    public var runtime: EngineRuntime
    /// The variant's measured peak memory.
    public var memoryBytes: Int64
    public var loadedAt: Date
    public var lastUsed: Date
    /// A job is using it right now; it won't be unloaded until the job ends.
    public var isBusy: Bool
    /// When the idle timer will unload it (nil: busy, or idle unloading is off).
    public var unloadsAt: Date?

    public var id: String { "\(modelID)@\(runtime.rawValue)" }
}

public enum JobKind: String, Codable, Sendable, Hashable, CaseIterable {
    case speech, transcription, referenceTranscription, voiceConversion, voiceDesign, conversation
}

/// A request waiting for, or running in, the one GPU slot.
public struct JobStatus: Codable, Sendable, Hashable, Identifiable {
    public enum State: String, Codable, Sendable { case queued, running }
    public var id: UUID
    public var kind: JobKind
    public var title: String
    public var modelID: String
    public var modelName: String
    public var state: State
    /// "Loading Qwen3-TTS…", "Generating 2 of 5"…
    public var stage: String?
    /// 0…1 when known.
    public var progress: Double?
    /// The runtime the job's model runs on, once chosen.
    public var runtime: EngineRuntime?
    public var enqueuedAt: Date
    public var startedAt: Date?
}

/// Everything the status object shows, as one value.
public struct RuntimeSnapshot: Codable, Sendable, Hashable {
    public var loaded: [LoadedModel] = []
    /// The running job first, then the queue in order.
    public var jobs: [JobStatus] = []
    public var memory: SystemMemory
    /// Models unloaded recently and why ("idle", "to make room for …", "on request"), newest last. Capped.
    public var recentUnloads: [UnloadEvent] = []
    public var version: Int = 0
}

public struct UnloadEvent: Codable, Sendable, Hashable {
    public var modelID: String
    public var runtime: EngineRuntime
    public var reason: String
    public var at: Date
}

/// SwiftUI's view of the model runtime: loaded models, memory, and the job queue for a global activity indicator.
/// Updated by `ModelRuntime`; read-only for the UI (actions go through `ModelRuntime`/`EncoreService`).
@MainActor @Observable
public final class RuntimeStatus {
    public private(set) var loaded: [LoadedModel] = []
    public private(set) var jobs: [JobStatus] = []
    public private(set) var memory: SystemMemory
    public private(set) var recentUnloads: [UnloadEvent] = []
    @ObservationIgnored private var version = -1

    public init(memory: SystemMemory = LiveSystemMemory().read()) {
        self.memory = memory
    }

    public var runningJob: JobStatus? { jobs.first { $0.state == .running } }
    public var queuedJobs: [JobStatus] { jobs.filter { $0.state == .queued } }
    public var isBusy: Bool { !jobs.isEmpty }
    /// Sum of the loaded models' peak memory.
    public var loadedBytes: Int64 { loaded.reduce(0) { $0 + $1.memoryBytes } }

    public func isLoaded(_ modelID: String) -> Bool { loaded.contains { $0.modelID == modelID } }

    /// Applies a snapshot; older snapshots arriving late are ignored.
    public func apply(_ snapshot: RuntimeSnapshot) {
        guard snapshot.version > version else { return }
        version = snapshot.version
        if loaded != snapshot.loaded { loaded = snapshot.loaded }
        if jobs != snapshot.jobs { jobs = snapshot.jobs }
        if memory != snapshot.memory { memory = snapshot.memory }
        if recentUnloads != snapshot.recentUnloads { recentUnloads = snapshot.recentUnloads }
    }
}
