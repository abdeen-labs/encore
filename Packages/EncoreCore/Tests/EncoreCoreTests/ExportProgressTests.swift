import Foundation
import Synchronization
import Testing
@testable import EncoreCore

/// Export progress: real encoder progress for WAV, M4A and MP3 (when ffmpeg is installed), conversions, and the
/// parsing of ffmpeg's `-progress` output.
@Suite("Export progress")
struct ExportProgressTests {
    /// Collects reported fractions from any thread.
    final class Recorder: Sendable {
        private let values = Mutex<[Double]>([])
        var report: ExportProgress { { [self] f in values.withLock { $0.append(f) } } }
        var all: [Double] { values.withLock { $0 } }
    }

    /// 40 s of tone: long enough for many encoder chunks.
    static let buffer = AudioBuffer(samples: Signal.sine(220, dbfs: -12, seconds: 40, rate: 24_000), sampleRate: 24_000)

    static func check(_ values: [Double], minimumSteps: Int, middle: Bool = true,
                      sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(values.count >= minimumSteps, "only \(values.count) progress reports", sourceLocation: sourceLocation)
        #expect((values.first ?? 1) < 0.2, sourceLocation: sourceLocation)
        #expect(values.last == 1, sourceLocation: sourceLocation)
        #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 }, sourceLocation: sourceLocation)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "progress went backwards", sourceLocation: sourceLocation)
        // Real progress, not just a start and an end: something in between.
        if middle { #expect(values.contains { $0 > 0.2 && $0 < 0.8 }, sourceLocation: sourceLocation) }
    }

    @Test(arguments: [AudioFileFormat.wav, .m4a])
    func systemEncodersReportProgress(format: AudioFileFormat) async throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("out.\(format.fileExtension)")
        let recorder = Recorder()
        try await AudioExporter.export(Self.buffer, to: url, format: format, progress: recorder.report)
        Self.check(recorder.all, minimumSteps: 5)
        let back = try await AudioReader.probe(url)
        #expect(abs(back.duration - 40) < 0.2)
    }

    @Test func mp3ReportsFFmpegProgress() async throws {
        guard FFmpeg.isAvailable else { return }  // MP3 needs the user's ffmpeg; without it nothing changes
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("out.mp3")
        let recorder = Recorder()
        try await AudioExporter.export(Self.buffer, to: url, format: .mp3, progress: recorder.report)
        // The staging WAV, then the position ffmpeg reports while it encodes (every half second, so a fast encode
        // may report only its final position).
        Self.check(recorder.all, minimumSteps: 3, middle: false)
        #expect(recorder.all.contains { $0 > 0 && $0 <= AudioExporter.mp3StagingShare })
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func conversionCoversReadingThenEncoding() async throws {
        let dir = try TempDir()
        let source = dir.url.appendingPathComponent("master.wav")
        try AudioExporter.writeWAV(Self.buffer, to: source, encoding: .pcm24)
        let recorder = Recorder()
        try await AudioExporter.convert(source, to: dir.url.appendingPathComponent("out.m4a"), format: .m4a, progress: recorder.report)
        let values = recorder.all
        Self.check(values, minimumSteps: 5)
        // Reading fills the first share of the bar, encoding the rest.
        #expect(values.contains { $0 > 0 && $0 <= AudioExporter.readShare })
        #expect(values.contains { $0 > AudioExporter.readShare + 0.1 && $0 < 1 })
    }

    @Test func noProgressHandlerWritesTheSameFile() async throws {
        let dir = try TempDir()
        let a = dir.url.appendingPathComponent("a.wav"), b = dir.url.appendingPathComponent("b.wav")
        try AudioExporter.writeWAV(Self.buffer, to: a, encoding: .pcm16)
        try AudioExporter.writeWAV(Self.buffer, to: b, encoding: .pcm16, progress: { _ in })
        #expect(try Data(contentsOf: a) == Data(contentsOf: b))  // chunking doesn't change the bytes (dither included)
    }

    @Test func canceledExportLeavesNoFile() async throws {
        let dir = try TempDir()
        let url = dir.url.appendingPathComponent("out.m4a")
        let task = Task {
            try await AudioExporter.export(Self.buffer, to: url, format: .m4a, progress: { f in
                if f > 0.1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(leftovers.isEmpty, "temporary file left: \(leftovers)")
    }

    @Test func parsesFFmpegProgressLines() {
        #expect(FFmpeg.progressSeconds("out_time_us=12500000") == 12.5)
        #expect(FFmpeg.progressSeconds("out_time_ms=2000000") == 2)  // microseconds despite the name
        #expect(FFmpeg.progressSeconds(" out_time_us=0 ") == 0)
        #expect(FFmpeg.progressSeconds("out_time_us=N/A") == nil)
        #expect(FFmpeg.progressSeconds("out_time=00:00:12.500000") == nil)
        #expect(FFmpeg.progressSeconds("progress=continue") == nil)
        #expect(FFmpeg.progressSeconds("total_size=1024") == nil)
    }

    @Test func outputCollectorSplitsLinesAcrossChunks() {
        let lines = Mutex<[String]>([])
        let collector = FFmpeg.OutputCollector(onLine: { line in lines.withLock { $0.append(line) } })
        collector.appendOut(Data("out_time_us=10".utf8))
        collector.appendOut(Data("00000\nprogress=cont".utf8))
        #expect(lines.withLock { $0 } == ["out_time_us=1000000"])
        collector.appendOut(Data("inue\n\n".utf8))
        #expect(lines.withLock { $0 } == ["out_time_us=1000000", "progress=continue"])
        #expect(String(decoding: collector.out, as: UTF8.self) == "out_time_us=1000000\nprogress=continue\n\n")
    }
}
