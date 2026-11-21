import AppKit
import EncoreCore
import SwiftUI

/// Everything the recording surface draws. Built from a live `AudioRecorder` with `init(_:)`, or by hand for
/// previews and snapshots (which must never touch the microphone).
struct RecordingDisplay: Equatable {
    var permission: AudioRecorder.Permission
    var isRecording: Bool
    var elapsed: TimeInterval
    /// RMS level, dBFS.
    var level: Float
    /// Recent levels, 0…1, oldest first.
    var levels: [Float]
    var failure: String?

    init(permission: AudioRecorder.Permission = .undetermined, isRecording: Bool = false, elapsed: TimeInterval = 0,
         level: Float = -160, levels: [Float] = [], failure: String? = nil) {
        self.permission = permission; self.isRecording = isRecording; self.elapsed = elapsed
        self.level = level; self.levels = levels; self.failure = failure
    }

    @MainActor init(_ recorder: AudioRecorder) {
        var failure: String?
        if case .failed(let message) = recorder.state { failure = message }
        self.init(permission: recorder.permission, isRecording: recorder.isRecording, elapsed: recorder.elapsed,
                  level: recorder.level, levels: recorder.recentLevels, failure: failure)
    }
}

/// The recording surface: live level history, elapsed time against the 5–15 s target, a velvet record/stop
/// button, and a clear path to System Settings when microphone access was denied.
///
///     RecordingPanel(state: RecordingDisplay(recorder), onRecord: { … }, onStop: { … })
struct RecordingPanel: View {
    let state: RecordingDisplay
    var target: ClosedRange<TimeInterval> = 5...15
    var onRecord: () -> Void
    var onStop: () -> Void

    var body: some View {
        Group {
            if state.permission == .denied {
                denied
            } else {
                recorder
            }
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }

    private var recorder: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Record").textRole(.eyebrow)
                    Text(headline).textRole(.headline)
                }
                Spacer()
                if state.isRecording { StatusBadge("Rec", tone: .danger, pulsing: true) }
                Text(Timecode.string(state.elapsed))
                    .textRole(.readout, color: state.isRecording ? .textPrimary : .textTertiary)
                    .contentTransition(.numericText())
            }
            LevelHistory(levels: state.levels, live: state.isRecording)
                .frame(height: 64)
                .padding(.horizontal, Theme.Space.s)
                .surface(.sunken, radius: Theme.Radius.m)
            TargetTimeline(elapsed: state.elapsed, target: target, isRecording: state.isRecording)
                .frame(height: 22)
            HStack(spacing: Theme.Space.m) {
                RecordButton(isRecording: state.isRecording) { state.isRecording ? onStop() : onRecord() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.isRecording ? "Stop when you've said a few sentences" : "Read a few natural sentences")
                        .textRole(.label)
                    Text(caption).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if state.isRecording { LevelReadout(level: state.level) }
            }
            if let failure = state.failure {
                Banner(.danger, title: "Recording stopped", message: failure)
            }
        }
    }

    private var headline: String {
        if state.isRecording { return "Listening…" }
        return state.elapsed > 0 ? "Take recorded" : "Your voice, \(Int(target.lowerBound))–\(Int(target.upperBound)) seconds"
    }

    private var caption: String {
        if state.permission == .undetermined && !state.isRecording {
            return "macOS will ask for microphone access the first time."
        }
        return "A quiet room and a steady distance from the mic work best."
    }

    private var denied: some View {
        HStack(alignment: .top, spacing: Theme.Space.l) {
            Image(systemName: "mic.slash")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.velvetText)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.velvet.opacity(0.1)))
                .overlay(Circle().strokeBorder(Color.velvet.opacity(0.3), lineWidth: 1))
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Microphone access is off").textRole(.section)
                Text("Encore needs the microphone to record a reference clip. Turn on Encore under Privacy & Security › Microphone, then come back. You can also drop in any audio file instead.")
                    .textRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Microphone Settings", systemImage: "gearshape") { Self.openMicrophoneSettings() }
                    .buttonStyle(.secondary)
                    .controlSize(.small)
                    .padding(.top, Theme.Space.xs)
            }
            Spacer(minLength: 0)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Drives a `RecordingPanel` from a live `AudioRecorder`. Only start/stop touch the microphone, and only when the
/// user presses the button.
struct RecorderView: View {
    let recorder: AudioRecorder
    var target: ClosedRange<TimeInterval> = 5...15
    var onFinished: (URL) -> Void

    var body: some View {
        RecordingPanel(state: RecordingDisplay(recorder), target: target) {
            Task { try? await recorder.start() }
        } onStop: {
            recorder.stop()
        }
        .onChange(of: recorder.state) { _, state in
            // Covers both the stop button and auto-stop at `maxDuration`.
            if case .finished(let url) = state { onFinished(url) }
        }
    }
}

// MARK: - Pieces

/// Scrolling bar history of input levels; newest on the right.
private struct LevelHistory: View {
    let levels: [Float]
    let live: Bool

    var body: some View {
        Canvas { ctx, size in
            let barWidth: CGFloat = 3, gap: CGFloat = 2
            let count = Int(size.width / (barWidth + gap))
            let mid = size.height / 2
            let shown = levels.suffix(count)
            let offset = count - shown.count
            for i in 0..<count {
                let x = CGFloat(i) * (barWidth + gap)
                if i < offset {
                    ctx.fill(Path(CGRect(x: x, y: mid - 0.5, width: barWidth, height: 1)), with: .color(Color.textTertiary.opacity(0.3)))
                    continue
                }
                let v = CGFloat(shown[shown.startIndex + i - offset])
                let h = max(2, v * (size.height - 6))
                let age = CGFloat(count - i) / CGFloat(count)
                let color: Color = live ? (v > 0.92 ? .footlight : .velvet) : .textTertiary
                ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - h / 2, width: barWidth, height: h), cornerRadius: 1.5),
                         with: .color(color.opacity(live ? 1 - Double(age) * 0.55 : 0.6)))
            }
        }
        .accessibilityLabel("Input level")
    }
}

/// 0 → 20 s line with the target window marked; fills as the take grows.
private struct TargetTimeline: View {
    let elapsed: TimeInterval
    let target: ClosedRange<TimeInterval>
    let isRecording: Bool

    var body: some View {
        GeometryReader { geo in
            let maxT = max(target.upperBound + 5, elapsed)
            let x: (TimeInterval) -> CGFloat = { geo.size.width * $0 / maxT }
            let inTarget = target.contains(elapsed)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.surfaceSunken).frame(height: 4).offset(y: 3)
                Capsule().fill(Color.mint.opacity(0.22))
                    .frame(width: x(target.upperBound) - x(target.lowerBound), height: 4)
                    .offset(x: x(target.lowerBound), y: 3)
                Capsule().fill(isRecording ? (inTarget ? Color.mint : .velvet) : .textTertiary)
                    .frame(width: max(4, x(min(elapsed, maxT))), height: 4)
                    .offset(y: 3)
                ForEach([target.lowerBound, target.upperBound], id: \.self) { t in
                    Text("\(Int(t)) s").textRole(.monoSmall, color: .textTertiary)
                        .offset(x: x(t) - 8, y: 10)
                }
            }
        }
        .accessibilityLabel("Take length")
        .accessibilityValue("\(Int(elapsed)) seconds of \(Int(target.lowerBound)) to \(Int(target.upperBound))")
    }
}

private struct LevelReadout: View {
    let level: Float
    var body: some View {
        Text(level > -100 ? String(format: "%.0f dBFS", level) : "— dBFS")
            .textRole(.monoSmall, color: level > -3 ? .footlight : .textSecondary)
    }
}

/// Big velvet record / stop button.
private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.velvet.opacity(0.12))
                Circle().strokeBorder(Color.velvet.opacity(isHovered ? 0.8 : 0.5), lineWidth: 1.5)
                if isRecording {
                    RoundedRectangle(cornerRadius: 3).fill(Color.velvet).frame(width: 15, height: 15)
                } else {
                    Circle().fill(Color.velvet).frame(width: 22, height: 22)
                }
            }
            .frame(width: 46, height: 46)
            .glow(.velvet, radius: 12, intensity: isRecording ? 0.6 : 0)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(isRecording ? "Stop recording" : "Record")
        .help(isRecording ? "Stop recording" : "Record")
    }
}
