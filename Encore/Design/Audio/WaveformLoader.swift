import Accelerate
import EncoreCore
import Foundation
import Observation

/// Loads waveform peaks for a file (streamed, progressively) or a buffer, for the waveform views.
/// Results for files are cached by path + modification date, so list rows that scroll back in don't re-read.
@Observable final class WaveformLoader {
    private(set) var peaks: WaveformPeaks?
    /// Known as soon as the file is probed, before peaks finish.
    private(set) var duration: TimeInterval = 0
    private(set) var sampleRate: Double = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Gain that makes the loudest peak fill the drawing height (capped, so near-silence stays flat).
    private(set) var displayGain: Float = 1

    @ObservationIgnored private var loadedKey: String?

    init() {}

    /// Fixed peaks (previews, gallery, or peaks computed elsewhere).
    init(peaks: WaveformPeaks) { apply(peaks) }

    func load(url: URL) async {
        let key = WaveformCache.key(for: url)
        guard key != loadedKey else { return }
        loadedKey = key
        errorMessage = nil
        if let cached = WaveformCache.shared[key] {
            apply(cached)
            return
        }
        isLoading = true
        defer { isLoading = false }
        if let info = try? await AudioReader.probe(url) {
            duration = info.duration
            sampleRate = info.sampleRate
        }
        do {
            let result = try await WaveformPeaks.compute(fileAt: url, bucketsPerSecond: 200) { partial in
                // Held only while this load runs.
                Task { @MainActor in
                    guard self.loadedKey == key, !(self.peaks?.isComplete ?? false) else { return }
                    self.apply(partial)
                }
            }
            guard loadedKey == key else { return }
            apply(result)
            WaveformCache.shared[key] = result
        } catch is CancellationError {
            loadedKey = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func load(buffer: AudioBuffer) async {
        let key = "buffer:\(buffer.samples.count):\(buffer.sampleRate):\(buffer.samples.prefix(64).hashValue)"
        guard key != loadedKey else { return }
        loadedKey = key
        duration = buffer.duration
        sampleRate = buffer.sampleRate
        let peaks = await Task.detached(priority: .userInitiated) {
            WaveformPeaks(buffer: buffer, samplesPerBucket: max(1, Int(buffer.sampleRate / 200)))
        }.value
        guard loadedKey == key else { return }
        apply(peaks)
    }

    private func apply(_ peaks: WaveformPeaks) {
        self.peaks = peaks
        if duration == 0 || peaks.isComplete { duration = peaks.duration }
        if sampleRate == 0 { sampleRate = peaks.sampleRate }
        displayGain = Self.gain(for: peaks)
    }

    nonisolated static func gain(for peaks: WaveformPeaks) -> Float {
        guard peaks.count > 0 else { return 1 }
        var hi: Float = 0, lo: Float = 0
        vDSP_maxv(peaks.maxs, 1, &hi, vDSP_Length(peaks.count))
        vDSP_minv(peaks.mins, 1, &lo, vDSP_Length(peaks.count))
        let peak = max(hi, -lo)
        guard peak > 0.0005 else { return 1 }
        return min(8, 0.92 / peak)
    }
}

/// Small in-memory cache of file peaks. Evicts oldest entries past a total bucket budget.
@MainActor final class WaveformCache {
    static let shared = WaveformCache()
    private var entries: [String: WaveformPeaks] = [:]
    private var order: [String] = []
    private let budget = 6_000_000 // base buckets (~72 MB)

    static func key(for url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)#\(date)"
    }

    subscript(key: String) -> WaveformPeaks? {
        get { entries[key] }
        set {
            entries[key] = newValue
            order.removeAll { $0 == key }
            if newValue != nil { order.append(key) }
            var total = entries.values.reduce(0) { $0 + $1.count }
            while total > budget, let oldest = order.first {
                order.removeFirst()
                total -= entries.removeValue(forKey: oldest)?.count ?? 0
            }
        }
    }
}

/// Timecodes for audio UI: `0:42.1`, `12:03.5`, `1:02:14`.
enum Timecode {
    static func string(_ t: TimeInterval, tenths: Bool = true) -> String {
        let t = max(0, t.isFinite ? t : 0)
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if tenths { return String(format: "%d:%02d.%d", m, s, Int((t - Double(total)) * 10) % 10) }
        return String(format: "%d:%02d", m, s)
    }

    /// Seconds with one decimal: `9.8 s`.
    static func seconds(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }
}
