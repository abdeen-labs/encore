import AppKit
import EncoreCore
import SwiftUI

/// What the Settings screen reads from the system: ffmpeg, the Python helper, and storage sizes.
/// Snapshots inject a prepared one so nothing real is probed.
@Observable final class SettingsModel {
    struct Helper: Equatable {
        var helperVersion: String
        var pythonVersion: String
        var mlxAudioVersion: String?
    }

    struct StorageItem: Identifiable, Equatable {
        var id: String { title }
        var title: String
        var detail: String
        var url: URL
        var bytes: Int64?
    }

    var ffmpeg: URL?
    var ffmpegChecked = false
    var python: PythonRuntime.Lookup?
    var helper: Helper?
    var storage: [StorageItem] = []
    @ObservationIgnored var isFixture = false

    func refreshFFmpeg(configuredPath: String?) {
        guard !isFixture else { return }
        ffmpeg = FFmpeg.locate(configuredPath: configuredPath)
        ffmpegChecked = true
    }

    func refreshPython(service: EncoreService) async {
        guard !isFixture else { return }
        python = PythonRuntime.locate()
        // Versions only when the helper is already running; Settings never starts it.
        if let backend = service.backends.compactMap({ $0 as? PythonBackend }).first, await backend.isRunning,
           let h = try? await backend.start() {
            helper = Helper(helperVersion: h.helperVersion, pythonVersion: h.pythonVersion,
                            mlxAudioVersion: h.packages["mlx-audio"] ?? h.packages["mlx_audio"])
        } else {
            helper = nil
        }
    }

    func refreshStorage(modelsBytes: Int64, hubCache: URL) async {
        guard !isFixture else { return }
        var items = [
            StorageItem(title: "Models", detail: "Hugging Face cache, shared with the hf CLI and Python", url: hubCache, bytes: modelsBytes),
            StorageItem(title: "History", detail: "Every take you've generated", url: EncorePaths.history, bytes: nil),
            StorageItem(title: "Voices", detail: "Your voice library and reference clips", url: EncorePaths.voices, bytes: nil),
        ]
        storage = items
        for i in 1..<items.count {
            let url = items[i].url
            items[i].bytes = await Task.detached(priority: .utility) { Self.directorySize(url) }.value
        }
        storage = items
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

extension EnvironmentValues {
    /// A prepared `SettingsModel` (fixtures); the screen makes its own when nil.
    @Entry var settingsModelOverride: SettingsModel? = nil
}
