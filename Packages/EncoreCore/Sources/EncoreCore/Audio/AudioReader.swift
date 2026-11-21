@preconcurrency import AVFoundation
import Foundation

/// What a media file contains, as far as Encore cares.
public struct MediaInfo: Sendable, Codable, Equatable {
    public enum Decoder: String, Sendable, Codable {
        /// Plain audio files AudioToolbox opens directly (wav, aiff, caf, m4a, mp3, flac…). Sample-accurate seeking.
        case audioFile
        /// Containers with an audio track that AVFoundation reads (mp4, mov, m4v…), including video.
        case avAsset
        /// Everything else, through the user's ffmpeg (mkv, webm, ogg, opus, wma…).
        case ffmpeg
    }

    public var duration: TimeInterval
    /// Native sample rate of the first audio track.
    public var sampleRate: Double
    public var channelCount: Int
    /// Short codec name: "lpcm", "aac", "mp3", "alac", "flac", "opus"… (best effort).
    public var codec: String?
    public var hasVideo: Bool
    /// File size in bytes.
    public var fileSize: Int64?
    public var decoder: Decoder
}

/// Decodes any audio or video file into mono Float32, optionally resampled and limited to a time range.
///
/// `AudioReader.read` loads the result into memory. For long inputs use `AudioFileReader` and pull chunks:
/// memory stays bounded and only the requested range is decoded.
public enum AudioReader {
    public static func probe(_ url: URL) async throws -> MediaInfo {
        try await AudioFileReader(url: url).info
    }

    /// Reads a file (or the part of it inside `range`, in seconds) as mono, at `sampleRate` if given,
    /// otherwise at the file's native rate.
    public static func read(_ url: URL, range: ClosedRange<TimeInterval>? = nil,
                            sampleRate: Double? = nil) async throws -> AudioBuffer {
        let reader = try await AudioFileReader(url: url, range: range, sampleRate: sampleRate)
        var samples: [Float] = []
        if let expected = reader.expectedFrameCount { samples.reserveCapacity(expected + 4096) }
        while let chunk = try reader.next() {
            try Task.checkCancellation()
            samples += chunk
        }
        return AudioBuffer(samples: samples, sampleRate: reader.outputSampleRate)
    }
}

/// Pull-based mono decoder for one file. Create it, then call `next()` until it returns nil.
/// Not thread-safe; use it from one task at a time.
public final class AudioFileReader: @unchecked Sendable {
    public let url: URL
    public let info: MediaInfo
    /// The rate of the samples `next()` returns.
    public let outputSampleRate: Double
    /// Requested range clamped to the media, in seconds.
    public let range: ClosedRange<TimeInterval>
    /// Frames `next()` will return in total, when known up front.
    public var expectedFrameCount: Int? {
        let n = Int(((range.upperBound - range.lowerBound) * outputSampleRate).rounded())
        return n >= 0 ? n : nil
    }

    private var source: ChunkSource

    public init(url: URL, range requested: ClosedRange<TimeInterval>? = nil, sampleRate: Double? = nil,
                chunkFrames: Int = 65_536) async throws {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioError.unreadable(path: url.path, reason: "The file doesn't exist.")
        }
        if let sampleRate, !(sampleRate > 0) { throw AudioError.invalidArgument("Sample rate must be positive.") }
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value

        let opened: (ChunkSource, MediaInfo)
        // Apple's MP3 decoder ignores the LAME gapless header and starts 576 samples late; ffmpeg is exact.
        let preferFFmpeg = url.pathExtension.lowercased() == "mp3" ? FFmpeg.locate() : nil
        if let ffmpeg = preferFFmpeg,
           let r = try? await FFmpegSource.open(url, ffmpeg: ffmpeg, fileSize: fileSize, chunkFrames: chunkFrames) {
            opened = r
        } else if var r = try? AudioFileSource.open(url, chunkFrames: chunkFrames, fileSize: fileSize) {
            // AudioToolbox also opens the audio of some movie files (mp4/mov); note the video for the UI.
            if !Self.audioOnlyExtensions.contains(url.pathExtension.lowercased()) {
                let videoTracks = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video)
                r.1.hasVideo = !(videoTracks ?? []).isEmpty
            }
            opened = r
        } else if let r = try await AssetReaderSource.open(url, fileSize: fileSize) {
            opened = r
        } else if let ffmpeg = FFmpeg.locate() {
            opened = try await FFmpegSource.open(url, ffmpeg: ffmpeg, fileSize: fileSize, chunkFrames: chunkFrames)
        } else {
            throw AudioError.needsFFmpegToRead(path: url.path)
        }
        var (decoder, info) = opened
        self.info = info

        let lower = max(0, requested?.lowerBound ?? 0)
        let upper = min(info.duration, requested?.upperBound ?? info.duration)
        guard lower <= upper || info.duration == 0 else {
            throw AudioError.invalidArgument("The range starts after the end of the media.")
        }
        range = lower...max(lower, upper)
        try decoder.seek(to: range)

        let target = sampleRate ?? decoder.sampleRate
        outputSampleRate = target
        if abs(target - decoder.sampleRate) > 0.01 {
            decoder = try ResamplingSource(decoder, to: target, chunkFrames: chunkFrames)
        }
        source = decoder
    }

    static let audioOnlyExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "aac",
                                                   "flac", "snd", "au"]

    /// The next block of mono samples, or nil at the end.
    public func next() throws -> [Float]? {
        // Decoders hand back autoreleased Foundation objects; drain them per chunk so long files stay bounded.
        try autoreleasepool { try source.next() }
    }
}

// MARK: - Chunk sources

protocol ChunkSource: AnyObject {
    var sampleRate: Double { get }
    /// Limit output to this time range (seconds into the media). Called once before the first `next()`.
    func seek(to range: ClosedRange<TimeInterval>) throws
    func next() throws -> [Float]?
}

/// AudioToolbox via AVAudioFile: plain audio files, sample-accurate.
final class AudioFileSource: ChunkSource {
    let file: AVAudioFile
    let sampleRate: Double
    let chunkFrames: AVAudioFrameCount
    private var remaining: AVAudioFramePosition
    private let buffer: AVAudioPCMBuffer

    private init(file: AVAudioFile, chunkFrames: Int) throws {
        self.file = file
        sampleRate = file.processingFormat.sampleRate
        self.chunkFrames = AVAudioFrameCount(chunkFrames)
        remaining = file.length
        guard let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: self.chunkFrames) else {
            throw AudioError.unreadable(path: file.url.path, reason: "Unsupported audio format.")
        }
        buffer = b
    }

    static func open(_ url: URL, chunkFrames: Int, fileSize: Int64?) throws -> (ChunkSource, MediaInfo) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.fileFormat.sampleRate > 0 else {
            throw AudioError.noAudioTrack(path: url.path)
        }
        let source = try AudioFileSource(file: file, chunkFrames: chunkFrames)
        let info = MediaInfo(duration: Double(file.length) / file.processingFormat.sampleRate,
                             sampleRate: file.processingFormat.sampleRate,
                             channelCount: Int(file.fileFormat.channelCount),
                             codec: codecName(file.fileFormat.streamDescription.pointee.mFormatID),
                             hasVideo: false, fileSize: fileSize, decoder: .audioFile)
        return (source, info)
    }

    func seek(to range: ClosedRange<TimeInterval>) throws {
        let start = min(file.length, AVAudioFramePosition((range.lowerBound * sampleRate).rounded()))
        let end = min(file.length, AVAudioFramePosition((range.upperBound * sampleRate).rounded()))
        file.framePosition = start
        remaining = max(0, end - start)
    }

    func next() throws -> [Float]? {
        guard remaining > 0 else { return nil }
        let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
        try file.read(into: buffer, frameCount: want)
        let got = Int(buffer.frameLength)
        guard got > 0 else { remaining = 0; return nil }
        remaining -= AVAudioFramePosition(got)
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(buffer.floatChannelData![$0]) }
        var out: [Float] = []
        out.reserveCapacity(got)
        AudioMath.mixdown(channels: channels, frames: got, into: &out)
        return out
    }
}

/// AVAssetReader: audio tracks inside movie containers (and anything else AVFoundation opens).
final class AssetReaderSource: ChunkSource {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let sampleRate: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    /// Frames still to deliver, to trim the decoder's overshoot at the end of the range.
    private var remaining = Int.max

    private init(asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double) {
        self.asset = asset; self.track = track; self.sampleRate = sampleRate
    }

    static func open(_ url: URL, fileSize: Int64?) async throws -> (ChunkSource, MediaInfo)? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let readable = try? await asset.load(.isReadable), readable else { return nil }
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        guard let track = audio.first else {
            // AVFoundation understood the container; there just isn't any sound in it.
            if !video.isEmpty { throw AudioError.noAudioTrack(path: url.path) }
            return nil
        }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        guard let asbd, asbd.mSampleRate > 0 else { return nil }
        var duration = (try? await track.load(.timeRange))?.duration.seconds ?? .nan
        if !duration.isFinite { duration = (try? await asset.load(.duration))?.seconds ?? 0 }
        let info = MediaInfo(duration: duration, sampleRate: asbd.mSampleRate, channelCount: Int(asbd.mChannelsPerFrame),
                             codec: codecName(asbd.mFormatID), hasVideo: !video.isEmpty, fileSize: fileSize,
                             decoder: .avAsset)
        return (AssetReaderSource(asset: asset, track: track, sampleRate: asbd.mSampleRate), info)
    }

    func seek(to range: ClosedRange<TimeInterval>) throws {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioError.unreadable(path: asset.url.path, reason: error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let scale: CMTimeScale = CMTimeScale(min(Double(Int32.max), sampleRate.rounded()))
        let start = CMTime(value: CMTimeValue((range.lowerBound * Double(scale)).rounded()), timescale: scale)
        let length = CMTime(value: CMTimeValue(((range.upperBound - range.lowerBound) * Double(scale)).rounded()),
                            timescale: scale)
        reader.timeRange = CMTimeRange(start: start, duration: length)
        remaining = Int(length.value)
        guard reader.startReading() else {
            throw AudioError.unreadable(path: asset.url.path,
                                        reason: reader.error?.localizedDescription ?? "AVAssetReader failed to start.")
        }
        self.reader = reader
        self.output = output
    }

    func next() throws -> [Float]? {
        guard let reader, let output, remaining > 0 else { return nil }
        while true {
            guard let sample = output.copyNextSampleBuffer() else {
                if reader.status == .failed {
                    throw AudioError.unreadable(path: asset.url.path, reason: reader.error?.localizedDescription ?? "Decoding failed.")
                }
                return nil
            }
            guard let format = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let channels = max(1, Int(asbd.mChannelsPerFrame))
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }
            var lengthAtOffset = 0, totalLength = 0
            var pointer: UnsafeMutablePointer<Int8>?
            var out: [Float] = []
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                                     totalLengthOut: &totalLength, dataPointerOut: &pointer)
            if status == kCMBlockBufferNoErr, let pointer, lengthAtOffset == totalLength {
                pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { p in
                    AudioMath.mixdown(interleaved: p, frames: frames, channels: channels, into: &out)
                }
            } else {
                // Non-contiguous block buffer: copy it out first.
                var data = [Float](repeating: 0, count: totalLength / MemoryLayout<Float>.size)
                data.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: totalLength, destination: raw.baseAddress!)
                }
                data.withUnsafeBufferPointer { p in
                    AudioMath.mixdown(interleaved: p.baseAddress!, frames: min(frames, data.count / channels),
                                      channels: channels, into: &out)
                }
            }
            if out.count > remaining { out.removeLast(out.count - remaining) }
            remaining -= out.count
            return out
        }
    }
}

/// ffmpeg decoding to raw float on stdout. Reads incrementally, so memory stays bounded.
final class FFmpegSource: ChunkSource {
    let url: URL
    let ffmpeg: URL
    let sampleRate: Double
    let channelCount: Int
    let chunkBytes: Int
    private var process: Process?
    private var pipe: Pipe?
    private var errors = FFmpeg.OutputCollector()
    private var carry = Data()

    private init(url: URL, ffmpeg: URL, sampleRate: Double, channelCount: Int, chunkFrames: Int) {
        self.url = url; self.ffmpeg = ffmpeg; self.sampleRate = sampleRate; self.channelCount = channelCount
        chunkBytes = chunkFrames * 4
    }

    deinit {
        if let process, process.isRunning { process.terminate() }
    }

    static func open(_ url: URL, ffmpeg: URL, fileSize: Int64?, chunkFrames: Int) async throws -> (ChunkSource, MediaInfo) {
        guard let probe = FFmpeg.locateProbe() else {
            throw AudioError.ffmpegMissing(purpose: "Reading this kind of file (ffprobe)")
        }
        let data: Data
        do {
            data = try await FFmpeg.run(probe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        } catch AudioError.ffmpegFailed(_, let message) {
            throw AudioError.unreadable(path: url.path, reason: message.isEmpty ? "Not a media file." : message)
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let streams = json["streams"] as? [[String: Any]] ?? []
        guard let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            if streams.isEmpty { throw AudioError.unreadable(path: url.path, reason: "Not a media file.") }
            throw AudioError.noAudioTrack(path: url.path)
        }
        let hasVideo = streams.contains {
            $0["codec_type"] as? String == "video"
                && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
        }
        let rate = Double(audio["sample_rate"] as? String ?? "") ?? 48_000
        let channels = audio["channels"] as? Int ?? 1
        let format = json["format"] as? [String: Any] ?? [:]
        let duration = Double(audio["duration"] as? String ?? "") ?? Double(format["duration"] as? String ?? "") ?? 0
        let info = MediaInfo(duration: duration, sampleRate: rate, channelCount: channels,
                             codec: audio["codec_name"] as? String, hasVideo: hasVideo, fileSize: fileSize, decoder: .ffmpeg)
        return (FFmpegSource(url: url, ffmpeg: ffmpeg, sampleRate: rate, channelCount: channels, chunkFrames: chunkFrames), info)
    }

    func seek(to range: ClosedRange<TimeInterval>) throws {
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error"]
        if range.lowerBound > 0 { args += ["-ss", String(format: "%.6f", range.lowerBound)] }
        args += ["-i", url.path, "-t", String(format: "%.6f", range.upperBound - range.lowerBound),
                 "-map", "0:a:0", "-vn", "-sn", "-dn"]
        if channelCount > 1 {
            // Plain average of all channels, matching the AVFoundation paths.
            let sum = (0..<channelCount).map { "c\($0)" }.joined(separator: "+")
            args += ["-af", "pan=mono|c0<\(sum)"]
        } else {
            args += ["-ac", "1"]
        }
        args += ["-ar", String(Int(sampleRate.rounded())), "-f", "f32le", "-acodec", "pcm_f32le", "pipe:1"]
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        let errors = self.errors
        err.fileHandleForReading.readabilityHandler = { h in errors.appendErr(h.availableData) }
        do { try process.run() } catch {
            throw AudioError.unreadable(path: url.path, reason: "Couldn't start ffmpeg: \(error.localizedDescription)")
        }
        self.process = process
        pipe = out
    }

    func next() throws -> [Float]? {
        guard let pipe, let process else { return nil }
        let data = try pipe.fileHandleForReading.read(upToCount: chunkBytes) ?? Data()
        if data.isEmpty {
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw AudioError.ffmpegFailed(status: process.terminationStatus, message: errors.errorTail)
            }
            self.pipe = nil
            return nil
        }
        carry.append(data)
        let usable = carry.count - carry.count % 4
        guard usable > 0 else { return try next() }
        var floats = [Float](repeating: 0, count: usable / 4)
        floats.withUnsafeMutableBytes { _ = carry.copyBytes(to: $0, from: carry.startIndex..<(carry.startIndex + usable)) }
        carry = Data(carry.dropFirst(usable))
        return floats
    }
}

/// Streaming sample-rate conversion with AVAudioConverter at maximum quality, no added latency.
final class ResamplingSource: ChunkSource {
    let input: ChunkSource
    let sampleRate: Double
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private let chunkFrames: AVAudioFrameCount
    private var inputEnded = false
    private var finished = false
    private var pullError: Error?

    /// `mastering` selects AudioToolbox's slowest, cleanest converter (~25× slower); the normal one at maximum
    /// quality is what streaming reads use and is plenty for speech models.
    init(_ input: ChunkSource, to rate: Double, chunkFrames: Int, mastering: Bool = false) throws {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.sampleRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioError.invalidArgument("Can't resample \(input.sampleRate) Hz to \(rate) Hz.")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = mastering ? AVSampleRateConverterAlgorithm_Mastering : AVSampleRateConverterAlgorithm_Normal
        self.input = input; sampleRate = rate; self.converter = converter
        self.inFormat = inFormat; self.outFormat = outFormat
        self.chunkFrames = AVAudioFrameCount(chunkFrames)
    }

    func seek(to range: ClosedRange<TimeInterval>) throws { try input.seek(to: range) }

    func next() throws -> [Float]? {
        guard !finished else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunkFrames) else { return nil }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { [self] _, inputStatus in
            if inputEnded { inputStatus.pointee = .endOfStream; return nil }
            do {
                guard let samples = try input.next(), !samples.isEmpty else {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))!
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                inputStatus.pointee = .haveData
                return buffer
            } catch {
                pullError = error
                inputEnded = true
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if let pullError { throw pullError }
        if status == .error {
            throw AudioError.invalidArgument("Resampling failed: \(error?.localizedDescription ?? "unknown error")")
        }
        if status == .endOfStream { finished = true }
        let n = Int(out.frameLength)
        if n == 0 { return finished ? nil : try next() }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
    }
}

func codecName(_ id: AudioFormatID) -> String {
    switch id {
    case kAudioFormatLinearPCM: "lpcm"
    case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2, kAudioFormatMPEG4AAC_LD,
         kAudioFormatMPEG4AAC_ELD: "aac"
    case kAudioFormatMPEGLayer3: "mp3"
    case kAudioFormatAppleLossless: "alac"
    case kAudioFormatFLAC: "flac"
    case kAudioFormatOpus: "opus"
    case kAudioFormatAC3: "ac3"
    case kAudioFormatEnhancedAC3: "eac3"
    case kAudioFormatAppleIMA4: "ima4"
    case kAudioFormatULaw: "ulaw"
    case kAudioFormatALaw: "alaw"
    default:
        String(bytes: withUnsafeBytes(of: id.bigEndian) { Array($0) }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces) ?? "unknown"
    }
}
