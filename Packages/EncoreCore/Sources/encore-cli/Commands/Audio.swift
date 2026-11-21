import EncoreCore
import EncoreMLX
import Foundation

private let audioUsage = """
usage: encore-cli audio <command> …
  probe <file>                                   container/codec/rate/duration
  read <file> [--start s] [--end s] [--rate hz] [--out f.wav]  decode (a range of) a file; prints time and peak memory
  convert <in> <out> [--format wav|m4a|mp3] [--bitrate kbps] [--wav pcm16|pcm24|float32] [--rate hz]
  loudness <file>                                BS.1770 integrated loudness, LRA, true peak (streamed)
  normalize <in> <out> [--target lufs] [--ceiling dbtp]
  desilence <in> <out> [--max s] [--pad s]
  post <in> <out> [--desilence] [--max s] [--target lufs]   PostProcessingOptions in one call
  peaks <file> [--bps n] [--columns n]           streamed waveform peaks; prints an ASCII overview
  segment <file> [--max s] [--min s]             cut points for long speech
  prep <in> <out>                                16 kHz mono WAV for transcription (streamed)
  record <out.wav> [--seconds n]                 microphone capture with live meter
  play <file> [--start s] [--end s]              headless playback through the default output
  ffmpeg                                         where ffmpeg was found
"""

func runAudioCommand(_ args: [String]) async throws {
    guard let command = args.first else { print(audioUsage); exit(2) }
    let opts = CLIOptions(Array(args.dropFirst()))
    switch command {
    case "probe":
        let info = try await AudioReader.probe(opts.url(0))
        printJSON(info)
    case "read":
        let range = opts.range
        let start = Date()
        let buffer = try await AudioReader.read(opts.url(0), range: range, sampleRate: opts.double("--rate"))
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "read %d samples (%.3f s at %.0f Hz) in %.3f s; peak %.1f dBFS; max RSS %.1f MB",
                     buffer.samples.count, buffer.duration, buffer.sampleRate, elapsed, buffer.peakDBFS, maxRSSMegabytes()))
        if let out = opts.string("--out") {
            try AudioExporter.writeWAV(buffer, to: URL(fileURLWithPath: out), encoding: .float32)
        }
    case "convert":
        let out = opts.url(1)
        guard let format = opts.string("--format").flatMap(AudioFileFormat.init(rawValue:))
                ?? AudioFileFormat(fileExtension: out.pathExtension) else {
            throw AudioError.invalidArgument("Unknown output format; use --format wav|m4a|mp3.")
        }
        var options = AudioExportOptions()
        if let b = opts.int("--bitrate") { options.aacBitrate = b; options.mp3Bitrate = b }
        if let w = opts.string("--wav").flatMap(WAVEncoding.init(rawValue:)) { options.wavEncoding = w }
        options.sampleRate = opts.double("--rate")
        let start = Date()
        try await AudioExporter.convert(opts.url(0), to: out, format: format, options: options)
        print(String(format: "wrote %@ in %.2f s", out.path, Date().timeIntervalSince(start)))
        printJSON(try await AudioReader.probe(out))
    case "loudness":
        let start = Date()
        let m = try await Loudness.measure(fileAt: opts.url(0))
        printJSON(m)
        print(String(format: "measured in %.2f s; max RSS %.1f MB", Date().timeIntervalSince(start), maxRSSMegabytes()))
    case "normalize":
        let buffer = try await AudioReader.read(opts.url(0))
        let (out, report) = Loudness.normalize(buffer, targetLUFS: opts.double("--target") ?? -16,
                                               truePeakCeiling: opts.double("--ceiling") ?? Loudness.defaultTruePeakCeiling)
        try await save(out, to: opts.url(1))
        printJSON(report)
    case "desilence":
        let buffer = try await AudioReader.read(opts.url(0))
        var o = SilenceRemovalOptions(maxSilence: opts.double("--max") ?? 0.6)
        if let pad = opts.double("--pad") { o.edgePadding = pad }
        o.thresholdDB = opts.double("--threshold")
        let out = PostProcessor.removeSilence(buffer, options: o)
        try await save(out, to: opts.url(1))
        print(String(format: "%.3f s → %.3f s", buffer.duration, out.duration))
    case "post":
        let buffer = try await AudioReader.read(opts.url(0))
        var p = PostProcessingOptions()
        p.removeSilence = opts.flag("--desilence")
        if let m = opts.double("--max") { p.maxSilenceSeconds = m }
        if let t = opts.double("--target") { p.targetLUFS = t }
        p.normalizeLoudness = !opts.flag("--no-normalize")
        let out = PostProcessor.apply(p, to: buffer)
        try await save(out, to: opts.url(1))
        let m = Loudness.measure(out)
        print(String(format: "%.3f s → %.3f s; %.2f LUFS → %.2f LUFS; true peak %.2f dBTP",
                     buffer.duration, out.duration, Loudness.integratedLoudness(buffer), m.integrated, m.truePeak))
    case "peaks":
        let start = Date()
        let updates = Counter()
        let peaks = try await WaveformPeaks.compute(fileAt: opts.url(0), bucketsPerSecond: opts.double("--bps") ?? 200) { _ in
            updates.increment()
        }
        let computed = Date().timeIntervalSince(start)
        let columns = opts.int("--columns") ?? 80
        let t0 = Date()
        let cols = peaks.buckets(count: columns)
        let rebucket = Date().timeIntervalSince(t0)
        let glyphs = Array(" ▁▂▃▄▅▆▇█")
        print(String(cols.map { glyphs[min(8, Int(($0.max - $0.min) / 2 * 8 * 1.999))] }))
        print(String(format: "%d base buckets (%d samples each) over %.1f s in %.2f s, %d progress updates; "
                     + "rebucket to %d in %.2f ms; max RSS %.1f MB",
                     peaks.count, peaks.samplesPerBucket, peaks.duration, computed, updates.value, columns,
                     rebucket * 1000, maxRSSMegabytes()))
    case "segment":
        let start = Date()
        let segments = try await SpeechSegmenter.segment(
            fileAt: opts.url(0),
            options: .init(maxDuration: opts.double("--max") ?? 20, minDuration: opts.double("--min") ?? 4))
        for s in segments {
            print(String(format: "%3d  %9.3f → %9.3f  (%6.3f s)%@", s.index, s.start, s.end, s.duration,
                         s.endsInPause ? "" : "  [no pause found]"))
        }
        print(String(format: "%d segments in %.2f s", segments.count, Date().timeIntervalSince(start)))
    case "prep":
        let start = Date()
        let url = try await AudioPreparation.transcriptionWAV(from: opts.url(0), to: opts.url(1))
        print(String(format: "wrote %@ in %.2f s; max RSS %.1f MB", url.path, Date().timeIntervalSince(start), maxRSSMegabytes()))
        printJSON(try await AudioReader.probe(url))
    case "record":
        try await record(to: opts.url(0), seconds: opts.double("--seconds") ?? 3)
    case "play":
        try await play(opts.url(0), range: opts.range)
    case "ffmpeg":
        print("ffmpeg:", FFmpeg.locate()?.path ?? "not found")
        print("ffprobe:", FFmpeg.locateProbe()?.path ?? "not found")
    default:
        print(audioUsage)
        exit(2)
    }
}

private func save(_ buffer: AudioBuffer, to url: URL) async throws {
    let format = AudioFileFormat(fileExtension: url.pathExtension) ?? .wav
    try await AudioExporter.export(buffer, to: url, format: format)
}

@MainActor
private func record(to url: URL, seconds: Double) async throws {
    setvbuf(stdout, nil, _IOLBF, 0)
    let recorder = AudioRecorder()
    print("microphone permission:", recorder.permission)
    if recorder.permission == .undetermined {
        print("macOS will ask for microphone access (attributed to the app that launched this process); waiting…")
    }
    recorder.maxDuration = seconds
    try await recorder.start(to: url)
    print("recording \(seconds) s…")
    var lastPrint = -1.0
    while recorder.isRecording {
        try await Task.sleep(for: .milliseconds(100))
        if recorder.elapsed - lastPrint >= 0.5 {
            lastPrint = recorder.elapsed
            print(String(format: "  %.1f s  level %.1f dBFS  peak %.1f dBFS", recorder.elapsed, recorder.level, recorder.peak))
        }
    }
    print("state:", recorder.state)
    if case .finished(let file) = recorder.state {
        printJSON(try await AudioReader.probe(file))
        let buffer = try await AudioReader.read(file)
        print(String(format: "recorded RMS %.1f dBFS, peak %.1f dBFS", buffer.rmsDBFS, buffer.peakDBFS))
    }
}

@MainActor
private func play(_ url: URL, range: ClosedRange<TimeInterval>?) async throws {
    let player = AudioPlayer()
    try await player.load(url: url)
    print(String(format: "loaded \"%@\", %.3f s", player.title ?? "", player.duration))
    let started = Date()
    if let range { player.play(range: range) } else { player.play() }
    print("now playing is this player:", NowPlaying.shared.player === player, "isPlaying:", player.isPlaying)
    var ticks: [Double] = []
    while player.isPlaying {
        try await Task.sleep(for: .milliseconds(250))
        ticks.append(player.currentTime)
    }
    print(String(format: "finished after %.2f s wall time; currentTime samples: %@; final currentTime %.3f; error: %@",
                 Date().timeIntervalSince(started), ticks.map { String(format: "%.2f", $0) }.joined(separator: " "),
                 player.currentTime, player.lastError ?? "none"))
}

// MARK: - Small helpers

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private struct CLIOptions {
    let positional: [String]
    let named: [String: String]
    let flags: Set<String>

    init(_ args: [String]) {
        var positional: [String] = [], named: [String: String] = [:], flags: Set<String> = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") || Double(args[i + 1]) != nil {
                    named[a] = args[i + 1]; i += 2
                } else {
                    flags.insert(a); i += 1
                }
            } else {
                positional.append(a); i += 1
            }
        }
        self.positional = positional; self.named = named; self.flags = flags
    }

    func url(_ i: Int) -> URL {
        guard i < positional.count else { print(audioUsage); exit(2) }
        return URL(fileURLWithPath: (positional[i] as NSString).expandingTildeInPath)
    }
    func string(_ k: String) -> String? { named[k] }
    func double(_ k: String) -> Double? { named[k].flatMap(Double.init) }
    func int(_ k: String) -> Int? { named[k].flatMap(Int.init) }
    func flag(_ k: String) -> Bool { flags.contains(k) || named[k] != nil }
    var range: ClosedRange<TimeInterval>? {
        let s = double("--start"), e = double("--end")
        if s == nil, e == nil { return nil }
        return (s ?? 0)...(e ?? .greatestFiniteMagnitude)
    }
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    if let data = try? encoder.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

private func maxRSSMegabytes() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576 // bytes on macOS
}
