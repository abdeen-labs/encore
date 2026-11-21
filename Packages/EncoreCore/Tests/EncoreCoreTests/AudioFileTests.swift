import Foundation
import Testing
@testable import EncoreCore

@Suite("Audio file I/O")
struct AudioFileTests {
    let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("EncoreAudioTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    @Test(arguments: WAVEncoding.allCases)
    func wavRoundTrip(encoding: WAVEncoding) async throws {
        let buffer = AudioBuffer(samples: Signal.sine(440, dbfs: -6, seconds: 1.5, rate: 24_000), sampleRate: 24_000)
        let url = dir.appendingPathComponent("rt-\(encoding).wav")
        try await AudioExporter.export(buffer, to: url, format: .wav, options: .init(wavEncoding: encoding))
        let info = try await AudioReader.probe(url)
        #expect(info.sampleRate == 24_000)
        #expect(info.decoder == .audioFile)
        let back = try await AudioReader.read(url)
        #expect(back.samples.count == buffer.samples.count)
        let tolerance: Float = switch encoding { case .pcm16: 2.0 / 32_768; case .pcm24: 1e-6; case .float32: 0 }
        let err = zip(back.samples, buffer.samples).map { abs($0 - $1) }.max() ?? 1
        #expect(err <= tolerance, "\(encoding): max error \(err)")
    }

    @Test func rangeReadIsSampleAccurate() async throws {
        let samples = (0..<48_000 * 4).map { Float($0 % 1000) / 1000 }
        let url = dir.appendingPathComponent("ramp.wav")
        try AudioExporter.writeWAV(AudioBuffer(samples: samples, sampleRate: 48_000), to: url, encoding: .float32)
        let part = try await AudioReader.read(url, range: 1.5...2.25)
        #expect(part.samples.count == 36_000)
        #expect(part.samples.first == samples[72_000])
        #expect(part.samples.last == samples[107_999])
        let resampled = try await AudioReader.read(url, range: 1...3, sampleRate: 16_000)
        #expect(resampled.samples.count == 32_000)
    }

    /// All three decoders must agree on what a time range contains (same samples, same alignment).
    @Test func decodersAgreeOnRanges() async throws {
        let buffer = AudioBuffer(samples: Signal.speechLike(seconds: 6, rate: 48_000), sampleRate: 48_000)
        let wav = dir.appendingPathComponent("agree.wav")
        try AudioExporter.writeWAV(buffer, to: wav, encoding: .float32)
        let m4a = dir.appendingPathComponent("agree.m4a")
        try AudioExporter.writeM4A(buffer, to: m4a, bitrate: 192)

        func drain(_ source: ChunkSource, _ range: ClosedRange<TimeInterval>) throws -> [Float] {
            try source.seek(to: range)
            var out: [Float] = []
            while let c = try source.next() { out += c }
            return out
        }
        func snr(_ a: [Float], _ b: [Float]) -> Double {
            let n = min(a.count, b.count)
            var sig = 0.0, err = 0.0
            for i in 0..<n { sig += Double(b[i] * b[i]); err += Double((a[i] - b[i]) * (a[i] - b[i])) }
            return 10 * log10(sig / max(err, 1e-30))
        }
        let range = 2.0...3.5
        let reference = Array(buffer.samples[96_000..<168_000])

        // AVAssetReader vs the exact source, on WAV and on AAC.
        let assetWAV = try #require(try await AssetReaderSource.open(wav, fileSize: nil)).0
        let fromAssetWAV = try drain(assetWAV, range)
        #expect(fromAssetWAV.count == reference.count)
        #expect(snr(fromAssetWAV, reference) > 100)

        let fileM4A = try AudioFileSource.open(m4a, chunkFrames: 4096, fileSize: nil).0
        let assetM4A = try #require(try await AssetReaderSource.open(m4a, fileSize: nil)).0
        let a = try drain(fileM4A, range), b = try drain(assetM4A, range)
        #expect(a.count == reference.count && b.count == reference.count)
        #expect(snr(a, reference) > 20, "AudioFile AAC range SNR \(snr(a, reference))")
        #expect(snr(b, reference) > 20, "AVAssetReader AAC range SNR \(snr(b, reference))")

        if let ffmpeg = FFmpeg.locate() {
            let ff = try await FFmpegSource.open(wav, ffmpeg: ffmpeg, fileSize: nil, chunkFrames: 4096).0
            let c = try drain(ff, range)
            #expect(c.count == reference.count)
            #expect(snr(c, reference) > 100)
        }
    }

    @Test func m4aRoundTrip() async throws {
        let buffer = AudioBuffer(samples: Signal.sine(440, dbfs: -6, seconds: 3, rate: 24_000), sampleRate: 24_000)
        let url = dir.appendingPathComponent("rt.m4a")
        try await AudioExporter.export(buffer, to: url, format: .m4a, options: .init(aacBitrate: 96))
        let info = try await AudioReader.probe(url)
        #expect(info.codec == "aac")
        #expect(abs(info.duration - 3) < 0.03)
        let back = try await AudioReader.read(url)
        #expect(abs(back.duration - 3) < 0.03)
        #expect(abs(back.rmsDBFS - buffer.rmsDBFS) < 0.5)
    }

    @Test func transcriptionPrepIs16kMono() async throws {
        let buffer = AudioBuffer(samples: Signal.sine(300, dbfs: -6, seconds: 2), sampleRate: 48_000)
        let src = dir.appendingPathComponent("src.wav")
        try AudioExporter.writeWAV(buffer, to: src, encoding: .float32)
        let out = try await AudioPreparation.transcriptionWAV(from: src, to: dir.appendingPathComponent("16k.wav"))
        let info = try await AudioReader.probe(out)
        #expect(info.sampleRate == 16_000 && info.channelCount == 1)
        #expect(abs(info.duration - 2) < 0.001)
    }

    @Test func peaksStreamFromFileMatchBuffer() async throws {
        let buffer = AudioBuffer(samples: Signal.speechLike(seconds: 3), sampleRate: 48_000)
        let url = dir.appendingPathComponent("peaks.wav")
        try AudioExporter.writeWAV(buffer, to: url, encoding: .float32)
        let fromFile = try await WaveformPeaks.compute(fileAt: url, bucketsPerSecond: 200)
        let fromBuffer = WaveformPeaks(buffer: buffer, samplesPerBucket: 240)
        // AudioToolbox flushes denormals when reading, so compare with a tolerance.
        #expect(fromFile.count == fromBuffer.count && fromFile.samplesPerBucket == fromBuffer.samplesPerBucket)
        let diff = zip(fromFile.maxs + fromFile.mins + fromFile.rms, fromBuffer.maxs + fromBuffer.mins + fromBuffer.rms)
            .map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 1e-6)
    }

    @Test func peaksComputationIsCancelable() async throws {
        let url = dir.appendingPathComponent("long-for-cancel.wav")
        try AudioExporter.writeWAV(AudioBuffer(samples: Signal.noise(seconds: 600, rmsDB: -20, rate: 16_000), sampleRate: 16_000),
                                   to: url, encoding: .pcm16)
        let task = Task { try await WaveformPeaks.compute(fileAt: url, bucketsPerSecond: 200) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func missingFileAndGarbage() async throws {
        await #expect(throws: AudioError.self) { try await AudioReader.read(dir.appendingPathComponent("nope.wav")) }
        let junk = dir.appendingPathComponent("junk.wav")
        try Data("not audio at all".utf8).write(to: junk)
        await #expect(throws: (any Error).self) { try await AudioReader.read(junk) }
    }

    @Test func ffmpegLocatorHonorsConfiguredPath() {
        #expect(FFmpeg.locate(configuredPath: "/nonexistent/ffmpeg") == FFmpeg.locate(configuredPath: ""))
        if let found = FFmpeg.locate() {
            #expect(FFmpeg.locate(configuredPath: found.deletingLastPathComponent().path) == found)
        }
    }
}
