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

    /// The app's Dock icon. `bubble` is the bundle's own icon; the others are alternates the app sets at launch.
    public enum AppIcon: String, Codable, Sendable, CaseIterable, Identifiable {
        case bubble, candy
        public var id: String { rawValue }
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
        public var appIcon: AppIcon = .bubble
        /// Serve the local API and MCP server on 127.0.0.1 while the app is open.
        public var localAPIEnabled: Bool = false
        public var localAPIPort: Int = Values.defaultLocalAPIPort

        public static let defaultLocalAPIPort = 7171

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
            appIcon = (try? c.decodeIfPresent(AppIcon.self, forKey: .appIcon)) ?? d.appIcon
            localAPIEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .localAPIEnabled)) ?? d.localAPIEnabled
            localAPIPort = (try? c.decodeIfPresent(Int.self, forKey: .localAPIPort)).flatMap { $0 } ?? d.localAPIPort
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(idleUnloadMinutes, forKey: .idleUnloadMinutes)
            try c.encode(defaultExportFormat, forKey: .defaultExportFormat)
            try c.encodeIfPresent(ffmpegPath, forKey: .ffmpegPath)
            try c.encode(postProcessing, forKey: .postProcessing)
            try c.encode(preferredRuntimes.mapValues(\.rawValue), forKey: .preferredRuntimes)
            try c.encode(Dictionary(uniqueKeysWithValues: lastUsedModels.map { ($0.key.rawValue, $0.value) }), forKey: .lastUsedModels)
            try c.encode(appIcon, forKey: .appIcon)
            try c.encode(localAPIEnabled, forKey: .localAPIEnabled)
            try c.encode(localAPIPort, forKey: .localAPIPort)
        }

        enum CodingKeys: String, CodingKey {
            case idleUnloadMinutes, defaultExportFormat, ffmpegPath, postProcessing, preferredRuntimes, lastUsedModels, appIcon
            case localAPIEnabled, localAPIPort
        }

        public static let defaults = Values()

        public func runtimePreference(for modelID: String) -> RuntimePreference { preferredRuntimes[modelID] ?? .automatic }
    }

    public var idleUnloadMinutes: Int { didSet { if idleUnloadMinutes < 0 { idleUnloadMinutes = 0 } else { save() } } }
    public var defaultExportFormat: ExportFormat { didSet { save() } }
    /// The source of truth for the ffmpeg override. Mirrored to `FFmpeg.userPathDefaultsKey` in the same
    /// UserDefaults, which is what `FFmpeg.locate()` reads.
    public var ffmpegPath: String? { didSet { save(); mirrorFFmpegPath() } }
    public var postProcessing: PostProcessingOptions { didSet { save() } }
    public var preferredRuntimes: [String: RuntimePreference] { didSet { save() } }
    public var lastUsedModels: [Feature: String] { didSet { save() } }
    public var appIcon: AppIcon { didSet { save() } }
    public var localAPIEnabled: Bool { didSet { save() } }
    /// 1024…65535; anything else is put back to the default.
    public var localAPIPort: Int {
        didSet {
            if !(1024...65535).contains(localAPIPort) { localAPIPort = Values.defaultLocalAPIPort } else { save() }
        }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored public nonisolated let key: String
    @ObservationIgnored private nonisolated let current = Mutex(Values())

    public init(defaults: UserDefaults = .standard, key: String = "EncoreSettings") {
        self.defaults = defaults
        self.key = key
        var v = Values()
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode(Values.self, from: data) { v = decoded }
        // Adopt an override written straight to the audio layer's key before settings owned it.
        if v.ffmpegPath == nil, let legacy = defaults.string(forKey: FFmpeg.userPathDefaultsKey), !legacy.isEmpty { v.ffmpegPath = legacy }
        idleUnloadMinutes = v.idleUnloadMinutes
        defaultExportFormat = v.defaultExportFormat
        ffmpegPath = v.ffmpegPath
        postProcessing = v.postProcessing
        preferredRuntimes = v.preferredRuntimes
        lastUsedModels = v.lastUsedModels
        appIcon = v.appIcon
        localAPIEnabled = v.localAPIEnabled
        localAPIPort = (1024...65535).contains(v.localAPIPort) ? v.localAPIPort : Values.defaultLocalAPIPort
        current.withLock { $0 = v }
        mirrorFFmpegPath()
    }

    private func mirrorFFmpegPath() {
        if let path = values.ffmpegPath { defaults.set(path, forKey: FFmpeg.userPathDefaultsKey) }
        else { defaults.removeObject(forKey: FFmpeg.userPathDefaultsKey) }
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
        v.appIcon = appIcon
        v.localAPIEnabled = localAPIEnabled
        v.localAPIPort = localAPIPort
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
        appIcon = d.appIcon
        localAPIEnabled = d.localAPIEnabled; localAPIPort = d.localAPIPort
    }

    private func save() {
        let v = values
        current.withLock { $0 = v }
        if let data = try? JSONEncoder().encode(v) { defaults.set(data, forKey: key) }
    }
}
