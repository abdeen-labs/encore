import Foundation
import Observation
import Synchronization

/// App-wide settings shared by the service layer and the UI, persisted in UserDefaults as one JSON value.
/// Each property saves on change. `snapshot()` is callable from any isolation (see StoreSupport.swift).
@MainActor @Observable
public final class AppSettings {
    public enum ExportFormat: String, Codable, Sendable, CaseIterable, Identifiable {
        case wav, m4a, mp3
        public var id: String { rawValue }
    }

    /// Which runtime to use for a model.
    public enum RuntimePreference: String, Codable, Sendable, CaseIterable, Identifiable {
        case automatic, mlxSwift, python
        public var id: String { rawValue }
        public var runtime: EngineRuntime? {
            switch self {
            case .automatic: nil
            case .mlxSwift: .mlxSwift
            case .python: .python
            }
        }
    }

    public enum Feature: String, Codable, Sendable, CaseIterable {
        case speech, cloning, voiceDesign, conversation, voiceChange, transcription
    }

    public struct Values: Codable, Sendable, Equatable {
        /// Unload a model after this many idle minutes; 0 = never.
        public var idleUnloadMinutes: Int = 10
        public var defaultExportFormat: ExportFormat = .wav
        /// Path to ffmpeg; nil = look in the usual places.
        public var ffmpegPath: String?
        public var postProcessing = PostProcessingOptions()
        /// Model id → runtime preference. Missing = automatic.
        public var preferredRuntimes: [String: RuntimePreference] = [:]
        /// Feature → last model id used for it.
        public var lastUsedModels: [Feature: String] = [:]

        public init() {}

        // Tolerant decoding: unknown or missing keys fall back to defaults, so the settings survive app updates.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Values.defaults
            idleUnloadMinutes = (try? c.decodeIfPresent(Int.self, forKey: .idleUnloadMinutes)) ?? d.idleUnloadMinutes
            defaultExportFormat = (try? c.decodeIfPresent(ExportFormat.self, forKey: .defaultExportFormat)) ?? d.defaultExportFormat
            ffmpegPath = (try? c.decodeIfPresent(String.self, forKey: .ffmpegPath)) ?? nil
            postProcessing = (try? c.decodeIfPresent(PostProcessingOptions.self, forKey: .postProcessing)) ?? d.postProcessing
            let runtimes = (try? c.decodeIfPresent([String: String].self, forKey: .preferredRuntimes)) ?? [:]
            preferredRuntimes = runtimes.compactMapValues(RuntimePreference.init(rawValue:))
            let last = (try? c.decodeIfPresent([String: String].self, forKey: .lastUsedModels)) ?? [:]
            lastUsedModels = Dictionary(uniqueKeysWithValues: last.compactMap { k, v in Feature(rawValue: k).map { ($0, v) } })
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
            try c.encode(defaultExportFormat, forKey: .defaultExportFormat)
            try c.encodeIfPresent(ffmpegPath, forKey: .ffmpegPath)
            try c.encode(postProcessing, forKey: .postProcessing)
            try c.encode(preferredRuntimes.mapValues(\.rawValue), forKey: .preferredRuntimes)
            try c.encode(Dictionary(uniqueKeysWithValues: lastUsedModels.map { ($0.key.rawValue, $0.value) }), forKey: .lastUsedModels)
        }

        enum CodingKeys: String, CodingKey {
            case idleUnloadMinutes, defaultExportFormat, ffmpegPath, postProcessing, preferredRuntimes, lastUsedModels
        }

        public static let defaults = Values()

        public func runtimePreference(for modelID: String) -> RuntimePreference { preferredRuntimes[modelID] ?? .automatic }
    }

    public var idleUnloadMinutes: Int { didSet { if idleUnloadMinutes < 0 { idleUnloadMinutes = 0 } else { save() } } }
    public var defaultExportFormat: ExportFormat { didSet { save() } }
    public var ffmpegPath: String? { didSet { save() } }
    public var postProcessing: PostProcessingOptions { didSet { save() } }
    public var preferredRuntimes: [String: RuntimePreference] { didSet { save() } }
    public var lastUsedModels: [Feature: String] { didSet { save() } }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public nonisolated let key: String
    @ObservationIgnored private nonisolated let current = Mutex(Values())

    public init(defaults: UserDefaults = .standard, key: String = "EncoreSettings") {
        self.defaults = defaults
        self.key = key
        var v = Values()
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Values.self, from: data) { v = decoded }
        idleUnloadMinutes = v.idleUnloadMinutes
        defaultExportFormat = v.defaultExportFormat
        ffmpegPath = v.ffmpegPath
        postProcessing = v.postProcessing
        preferredRuntimes = v.preferredRuntimes
        lastUsedModels = v.lastUsedModels
        current.withLock { $0 = v }
    }

    /// The current values, from any isolation.
    public nonisolated func snapshot() -> Values { current.withLock { $0 } }

    public var values: Values {
        var v = Values()
        v.idleUnloadMinutes = idleUnloadMinutes
        v.defaultExportFormat = defaultExportFormat
        v.ffmpegPath = ffmpegPath.flatMap { $0.trimmed().isEmpty ? nil : $0 }
        v.postProcessing = postProcessing
        v.preferredRuntimes = preferredRuntimes.filter { $0.value != .automatic }
        v.lastUsedModels = lastUsedModels
        return v
    }

    public func runtimePreference(for modelID: String) -> RuntimePreference { preferredRuntimes[modelID] ?? .automatic }
    public func setRuntimePreference(_ p: RuntimePreference, for modelID: String) { preferredRuntimes[modelID] = p == .automatic ? nil : p }
    public func noteModelUsed(_ modelID: String, for feature: Feature) {
        if lastUsedModels[feature] != modelID { lastUsedModels[feature] = modelID }
    }

    public func resetToDefaults() {
        let d = Values.defaults
        idleUnloadMinutes = d.idleUnloadMinutes; defaultExportFormat = d.defaultExportFormat; ffmpegPath = d.ffmpegPath
        postProcessing = d.postProcessing; preferredRuntimes = d.preferredRuntimes; lastUsedModels = d.lastUsedModels
    }

    private func save() {
        let v = values
        current.withLock { $0 = v }
        if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
    }
}
