import AVFoundation
import Foundation
import Testing
@testable import EncoreCore

/// Exercises the recorder's write/meter path with synthetic buffers. Never touches an input device.
@Suite("Audio recorder sink (no microphone)")
struct AudioRecorderSinkTests {
    @Test func sinkMixesWritesAndMeters() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sink-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let rate = 48_000.0
        let sink = RecordingSink(writer: try WAVWriter(url: url, sampleRate: rate, encoding: .float32), sampleRate: rate)
        let levels = LevelLog()
        sink.onLevels = { rms, peak, frames in levels.append(rms, peak, frames) }

        // Stereo, deinterleaved: left 0.5, right 0.1 → mono 0.3 (−10.46 dBFS).
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        for _ in 0..<50 {
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            b.frameLength = 960
            for i in 0..<960 { b.floatChannelData![0][i] = 0.5; b.floatChannelData![1][i] = 0.1 }
            sink.consume(b)
        }
        sink.close()
        #expect(sink.error == nil)

        let back = try await AudioReader.read(url)
        #expect(back.samples.count == 48_000)
        #expect(back.samples.allSatisfy { abs($0 - 0.3) < 1e-6 })
        let log = levels.entries
        // A reading once ≥ 50 ms has accumulated: every 3rd 960-frame buffer (2880 frames).
        #expect(log.count == 16)
        #expect(log.allSatisfy { abs($0.rms - -10.457) < 0.01 && abs($0.peak - -10.457) < 0.01 })
        #expect(log.last?.frames == 16 * 2_880)

        // Writes after close are ignored.
        let late = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
        late.frameLength = 960
        sink.consume(late)
        #expect(try await AudioReader.read(url).samples.count == 48_000)
    }
}

private final class LevelLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(rms: Float, peak: Float, frames: Int)] = []
    func append(_ r: Float, _ p: Float, _ f: Int) { lock.withLock { items.append((r, p, f)) } }
    var entries: [(rms: Float, peak: Float, frames: Int)] { lock.withLock { items } }
}
