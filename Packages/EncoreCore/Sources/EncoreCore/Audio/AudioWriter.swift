@preconcurrency import AVFoundation
import Accelerate
import Foundation

public enum AudioFileFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case wav, m4a, mp3
    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var displayName: String {
        switch self {
        case .wav: "WAV"
        case .m4a: "M4A (AAC)"
        case .mp3: "MP3"
        }
    }
    /// MP3 encoding goes through the user's ffmpeg.
    public var needsFFmpeg: Bool { self == .mp3 }

    public init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "wav", "wave": self = .wav
        case "m4a", "aac", "mp4": self = .m4a
        case "mp3": self = .mp3
        default: return nil
        }
    }
}

public enum WAVEncoding: String, Codable, Sendable, CaseIterable, Identifiable {
    case pcm16, pcm24, float32
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .pcm16: "16-bit"
        case .pcm24: "24-bit"
        case .float32: "32-bit float"
        }
    }
    var bytesPerSample: Int { switch self { case .pcm16: 2; case .pcm24: 3; case .float32: 4 } }
}

public struct AudioExportOptions: Codable, Sendable, Hashable {
    public var wavEncoding: WAVEncoding = .pcm16
    /// AAC bitrate in kbit/s. Rounded to the nearest rate the encoder allows for the sample rate.
    public var aacBitrate: Int = 128
    /// MP3 constant bitrate in kbit/s.
    public var mp3Bitrate: Int = 192
    /// Write at this rate instead of the buffer's (resampled at high quality).
    public var sampleRate: Double?

    public static let aacBitrates = [64, 96, 128, 160, 192, 256]
    public static let mp3Bitrates = [96, 128, 160, 192, 256, 320]

    public init(wavEncoding: WAVEncoding = .pcm16, aacBitrate: Int = 128, mp3Bitrate: Int = 192, sampleRate: Double? = nil) {
        self.wavEncoding = wavEncoding; self.aacBitrate = aacBitrate; self.mp3Bitrate = mp3Bitrate; self.sampleRate = sampleRate
    }
}

/// The one entry point the UI calls to save audio.
public enum AudioExporter {
    /// Writes `buffer` to `url` in `format`. The file is written to a temporary name and moved into place,
    /// so a failed or cancelled export never leaves a half-written file behind.
    public static func export(_ buffer: AudioBuffer, to url: URL, format: AudioFileFormat,
                              options: AudioExportOptions = AudioExportOptions()) async throws {
        var buffer = buffer
        if let rate = options.sampleRate, abs(rate - buffer.sampleRate) > 0.01 {
            buffer = try AudioEdit.resample(buffer, to: rate)
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temp) }
        switch format {
        case .wav: try writeWAV(buffer, to: temp, encoding: options.wavEncoding)
        case .m4a: try writeM4A(buffer, to: temp, bitrate: options.aacBitrate)
        case .mp3: try await writeMP3(buffer, to: temp, bitrate: options.mp3Bitrate)
        }
        try Task.checkCancellation()
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            throw AudioError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    /// Re-encodes any readable media file (audio or video) into `format`.
    public static func convert(_ source: URL, to url: URL, format: AudioFileFormat,
                               options: AudioExportOptions = AudioExportOptions()) async throws {
        let buffer = try await AudioReader.read(source, sampleRate: options.sampleRate)
        var options = options
        options.sampleRate = nil
        try await export(buffer, to: url, format: format, options: options)
    }

    // MARK: Encoders

    public static func writeWAV(_ buffer: AudioBuffer, to url: URL, encoding: WAVEncoding = .pcm16) throws {
        let writer = try WAVWriter(url: url, sampleRate: buffer.sampleRate, encoding: encoding)
        try writer.append(buffer.samples)
        try writer.finish()
    }

    public static func writeM4A(_ buffer: AudioBuffer, to url: URL, bitrate kbps: Int = 128) throws {
        var buffer = buffer
        // AAC-LC tops out at 48 kHz; anything above is resampled down.
        if buffer.sampleRate > 48_000 { buffer = try AudioEdit.resample(buffer, to: 48_000) }
        let rate = buffer.sampleRate
        let bitrate = aacBitrate(near: kbps * 1000, sampleRate: rate)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try writeChunks(buffer, to: file)
        } catch let error as AudioError {
            throw error
        } catch {
            throw AudioError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    public static func writeMP3(_ buffer: AudioBuffer, to url: URL, bitrate kbps: Int = 192) async throws {
        let ffmpeg = try FFmpeg.require(for: "MP3 export")
        let wav = EncorePaths.scratch.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        try writeWAV(buffer, to: wav, encoding: .float32)
        // MP3 supports 8–48 kHz; let LAME pick the nearest legal rate otherwise.
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", wav.path,
                    "-codec:a", "libmp3lame", "-b:a", "\(kbps)k"]
        if buffer.sampleRate > 48_000 { args += ["-ar", "48000"] }
        args += ["-f", "mp3", url.path]
        try await FFmpeg.run(ffmpeg, args)
    }

    static func writeChunks(_ buffer: AudioBuffer, to file: AVAudioFile) throws {
        let chunk = 32_768
        guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
            throw AudioError.writeFailed(path: file.url.path, reason: "Unsupported format.")
        }
        var offset = 0
        try buffer.samples.withUnsafeBufferPointer { src in
            while offset < src.count {
                let n = min(chunk, src.count - offset)
                pcm.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
                pcm.frameLength = AVAudioFrameCount(n)
                try file.write(from: pcm)
                offset += n
            }
        }
    }

    /// The nearest bitrate the AAC encoder accepts for mono at `sampleRate`.
    static func aacBitrate(near requested: Int, sampleRate: Double) -> Int {
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let output = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                    AVNumberOfChannelsKey: 1]),
              let converter = AVAudioConverter(from: input, to: output),
              let rates = converter.applicableEncodeBitRates?.map(\.intValue), !rates.isEmpty else {
            return requested
        }
        return rates.min { abs($0 - requested) < abs($1 - requested) } ?? requested
    }
}

/// Streaming RIFF/WAVE writer for mono audio. 16-bit output is TPDF-dithered.
public final class WAVWriter {
    public let url: URL
    public let sampleRate: Double
    public let encoding: WAVEncoding
    public private(set) var framesWritten: Int = 0
    private let handle: FileHandle
    private var finished = false
    private var ditherPhase = 0
    /// TPDF dither values in LSBs (sum of two uniform ±0.5), long enough that its period is inaudible.
    private static let dither: [Float] = {
        var x: UInt32 = 0x9E37_79B9
        return (0..<131_072).map { _ in
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return (Float(x & 0xFFFF) + Float(x >> 16)) / 65_535 - 1
        }
    }()

    public init(url: URL, sampleRate: Double, encoding: WAVEncoding = .pcm16) throws {
        guard sampleRate > 0 else { throw AudioError.invalidArgument("Sample rate must be positive.") }
        self.url = url; self.sampleRate = sampleRate; self.encoding = encoding
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw AudioError.writeFailed(path: url.path, reason: "Can't create the file.")
        }
        self.handle = handle
        try handle.write(contentsOf: header(dataBytes: 0))
    }

    deinit { try? finish() }

    public func append(_ samples: [Float]) throws {
        guard !finished, !samples.isEmpty else { return }
        let bytes = samples.count * encoding.bytesPerSample
        guard UInt64(framesWritten + samples.count) * UInt64(encoding.bytesPerSample) + 44 < UInt64(UInt32.max) else {
            throw AudioError.writeFailed(path: url.path, reason: "WAV files can't exceed 4 GB.")
        }
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            switch encoding {
            case .float32:
                samples.withUnsafeBytes { raw.copyMemory(from: $0) }
            case .pcm16:
                // Scale, add TPDF dither (±1 LSB) from a precomputed table, clip, round — all vectorised.
                let n = samples.count
                var scaled = [Float](repeating: 0, count: n)
                var scale: Float = 32_767
                var done = 0
                while done < n {
                    let take = min(n - done, Self.dither.count - ditherPhase)
                    samples.withUnsafeBufferPointer { src in
                        Self.dither.withUnsafeBufferPointer { d in
                            vDSP_vsma(src.baseAddress! + done, 1, &scale, d.baseAddress! + ditherPhase, 1,
                                      &scaled[done], 1, vDSP_Length(take))
                        }
                    }
                    done += take
                    ditherPhase = (ditherPhase + take) % Self.dither.count
                }
                var lo: Float = -32_768, hi: Float = 32_767
                vDSP_vclip(scaled, 1, &lo, &hi, &scaled, 1, vDSP_Length(n))
                vDSP_vfixr16(scaled, 1, raw.bindMemory(to: Int16.self).baseAddress!, 1, vDSP_Length(n))
            case .pcm24:
                let out = raw.bindMemory(to: UInt8.self)
                for i in 0..<samples.count {
                    let s = samples[i].isNaN ? 0 : Double(samples[i])
                    let v = Int32(max(-8_388_608, min(8_388_607, (s * 8_388_607).rounded())))
                    out[3 * i] = UInt8(truncatingIfNeeded: v)
                    out[3 * i + 1] = UInt8(truncatingIfNeeded: v >> 8)
                    out[3 * i + 2] = UInt8(truncatingIfNeeded: v >> 16)
                }
            }
        }
        do { try handle.write(contentsOf: data) } catch {
            throw AudioError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
        framesWritten += samples.count
    }

    /// Patches the header with the final sizes and closes the file. Safe to call twice.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: header(dataBytes: framesWritten * encoding.bytesPerSample))
            try handle.close()
        } catch {
            throw AudioError.writeFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    private func header(dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bps = encoding.bytesPerSample
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(encoding == .float32 ? 3 : 1) // WAVE_FORMAT_IEEE_FLOAT : WAVE_FORMAT_PCM
        u16(1)
        u32(UInt32(sampleRate.rounded()))
        u32(UInt32(sampleRate.rounded()) * UInt32(bps))
        u16(UInt16(bps))
        u16(UInt16(bps * 8))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }
}

/// Input preparation for speech-to-text engines.
public enum AudioPreparation {
    /// Decodes any audio/video file to a 16 kHz mono 16-bit WAV, streaming (bounded memory, any length).
    /// Returns `destination`, or a new file in the scratch folder.
    public static func transcriptionWAV(from source: URL, to destination: URL? = nil,
                                        range: ClosedRange<TimeInterval>? = nil,
                                        progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        try await wav(from: source, to: destination, sampleRate: 16_000, range: range, progress: progress)
    }

    /// Streams any media file to a mono WAV at `sampleRate` (native when nil).
    public static func wav(from source: URL, to destination: URL? = nil, sampleRate: Double? = nil,
                           encoding: WAVEncoding = .pcm16, range: ClosedRange<TimeInterval>? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let url = destination ?? EncorePaths.scratch.appendingPathComponent("\(UUID().uuidString).wav")
        let reader = try await AudioFileReader(url: source, range: range, sampleRate: sampleRate)
        let writer = try WAVWriter(url: url, sampleRate: reader.outputSampleRate, encoding: encoding)
        let total = Double(max(1, reader.expectedFrameCount ?? 1))
        do {
            while let chunk = try reader.next() {
                try Task.checkCancellation()
                try writer.append(chunk)
                progress?(min(1, Double(writer.framesWritten) / total))
            }
            try writer.finish()
        } catch {
            try? writer.finish()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        progress?(1)
        return url
    }
}
