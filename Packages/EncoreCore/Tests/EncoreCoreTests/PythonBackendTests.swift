import Foundation
import Testing
@testable import EncoreCore

@Suite struct PythonBackendTests {
    @Test func readsFloatWAVWithUnalignedData() throws {
        // Same layout the helper writes: fmt (18 bytes) + fact, so the data chunk starts at byte 58.
        let samples: [Float] = [0, 0.5, -0.25, 1]
        var d = Data("RIFF".utf8)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        u32(UInt32(4 + 26 + 12 + 8 + samples.count * 4)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(18); u16(3); u16(1); u32(24000); u32(96000); u16(4); u16(32); u16(0)
        d.append(contentsOf: Array("fact".utf8)); u32(4); u32(UInt32(samples.count))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 4))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("python-wav-test-\(UUID()).wav")
        try d.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try PythonWAV.read(url)
        #expect(audio.sampleRate == 24000)
        #expect(audio.samples == samples)
    }

    @Test func helperEnvironmentIsSealed() {
        let runtime = PythonRuntime(executable: URL(fileURLWithPath: "/x/python/bin/python3"),
                                    helperRoot: URL(fileURLWithPath: "/x/PythonHelper"), origin: .override)
        let env = runtime.environment(ffmpegDirectory: URL(fileURLWithPath: "/opt/ffmpeg/bin"))
        #expect(env["PYTHONPATH"] == "/x/PythonHelper")
        #expect(env["HF_HUB_OFFLINE"] == "1")
        #expect(env["PYTHONDONTWRITEBYTECODE"] == "1")
        #expect(env["PATH"]?.hasPrefix("/x/python/bin:/opt/ffmpeg/bin:") == true)
        #expect(env["HF_HUB_CACHE"] == EncorePaths.huggingFaceHub.path)
        #expect(env["PYTHONHOME"] == nil)
    }

    @Test func voiceConversionManifestDecodes() throws {
        let (catalog, problems) = ModelCatalog.bundled()
        #expect(!problems.contains { $0.contains("chatterbox-vc") })
        let vc = try #require(catalog.model("chatterbox-vc"))
        #expect(vc.engine == "chatterbox_vc")
        #expect(vc.tasks == [.voiceConversion])
        #expect(vc.defaultVariant.allRepos == ["mlx-community/chatterbox-multilingual-v3", "mlx-community/S3TokenizerV2"])
        #expect(vc.defaultParameters["n_timesteps"] == .int(10))
    }

    /// Starts the real helper when the dev runtime exists (Scripts/setup-python-runtime.sh); skipped otherwise.
    @Test func handshakeReportsVoiceConversion() async throws {
        guard case .found = PythonRuntime.locate() else { return }
        let backend = PythonBackend()
        #expect(await backend.availability() == .ready)
        let features = await backend.engineFeatures()
        #expect(features["chatterbox_vc"] == .voiceConversion)
        #expect(features["whisper"]?.contains(.wordTimestamps) == true)
        await backend.shutdown()
        #expect(await backend.isRunning == false)
    }
}
