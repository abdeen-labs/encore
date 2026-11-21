import EncoreCore
import SwiftUI

/// The one way every generation screen starts, watches and cancels a job.
///
/// Idle: the primary action (⌘↩ unless something else on the screen has that key), plus a note on why it
/// can't run yet or how the last job went.
/// Waiting: queue position and what is running ahead. Running: stage, progress, elapsed time, Cancel (⌘.).
/// Memory warning: a title, one sentence, the bar and its numbers, and "Run anyway" / "Not now".
///
///     RunSurface(runner: runner, title: "Perform", systemImage: "play.fill",
///                blockedReason: canRun ? nil : "Write something first", action: perform)
struct RunSurface: View {
    let runner: JobRunner
    var title: String
    var systemImage: String = "play.fill"
    /// When non-nil the action is disabled and this says why.
    var blockedReason: String?
    /// Idle note shown when nothing else needs saying: one short sentence, one line.
    var idleNote: String?
    /// One owner per key on a screen. False while something else has ⌘↩ (a save form), or for a second
    /// run surface beside the screen's own.
    var runShortcut = true
    /// False for a second run surface on a screen, so ⌘. cancels the screen's own job.
    var cancelShortcut = true
    let action: () -> Void

    @Environment(RuntimeStatus.self) private var status

    var body: some View {
        Group {
            switch runner.phase {
            case .idle, .checkingMemory: idle
            case .confirmMemory(let a): MemoryWarning(assessment: a, modelName: runner.identity?.modelName ?? "This model",
                                                      onRun: runner.runAnyway, onCancel: runner.dismissMemoryWarning,
                                                      runShortcut: runShortcut, cancelShortcut: cancelShortcut)
            case .running: running
            }
        }
        .stageAnimation(Theme.Motion.standard, value: runner.phase)
    }

    // MARK: Idle

    private var idle: some View {
        HStack(spacing: Theme.Space.m) {
            Button(title, systemImage: systemImage, action: action)
                .buttonStyle(.primary)
                .controlSize(.large)
                .keyboardShortcut(runShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .disabled(blockedReason != nil || runner.phase == .checkingMemory)
                .help(runShortcut ? "\(title) (⌘↩)" : title)
            VStack(alignment: .leading, spacing: 2) {
                if runner.phase == .checkingMemory {
                    Text("Checking memory…").textRole(.caption)
                } else if let blockedReason {
                    Text(blockedReason).textRole(.caption).lineLimit(2)
                } else {
                    if let note = outcomeNote {
                        Text(note).textRole(.caption, color: .textSecondary).lineLimit(1)
                    }
                    if let idleNote {
                        Text(idleNote).textRole(.caption, color: .textTertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
            Text("⌘↩").textRole(.monoSmall, color: .textTertiary)
                .opacity(blockedReason == nil && runShortcut ? 1 : 0)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Theme.ControlHeight.large)
    }

    private var outcomeNote: String? {
        switch runner.lastOutcome {
        case .finished(let t)?: "Done in \(Self.seconds(t))."
        case .canceled?: "Canceled. Nothing was saved."
        default: nil
        }
    }

    // MARK: Running

    /// Our job's place in the GPU queue (1 = next), and what's running ahead of it.
    private var queue: (position: Int, ahead: JobStatus?)? {
        guard let id = runner.identity, !runner.hasStarted else { return nil }
        let queued = status.queuedJobs
        guard let i = queued.firstIndex(where: { $0.kind == id.kind && $0.modelID == id.modelID }) else { return nil }
        return (i + 1, status.runningJob)
    }

    private var running: some View {
        HStack(alignment: .center, spacing: Theme.Space.m) {
            ActivityIndicator(tone: queue == nil ? .accent : .neutral, size: 18)
                .frame(width: Theme.ControlHeight.large, height: Theme.ControlHeight.large)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(stageLine).textRole(.headline).lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    ElapsedLabel(since: runner.startedAt)
                }
                ProgressBar(value: queue == nil ? runner.progress : nil, tone: queue == nil ? .accent : .neutral)
            }
            Button("Cancel", systemImage: "stop.fill", action: runner.cancel)
                .buttonStyle(.secondary)
                .keyboardShortcut(cancelShortcut ? KeyboardShortcut(".", modifiers: .command) : nil)
                .help(cancelShortcut ? "Cancel (⌘.)" : "Cancel")
        }
        .frame(minHeight: Theme.ControlHeight.large)
    }

    private var stageLine: String {
        if let q = queue {
            let what = q.ahead.map { "“\($0.title)” is running" } ?? "Another job is running"
            return q.position == 1 ? "Waiting — \(what)" : "Waiting, \(Self.ordinal(q.position)) in line — \(what)"
        }
        return runner.stage ?? "Starting…"
    }

    static func seconds(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1f s", t) : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : ["th", "st", "nd", "rd", "th", "th", "th", "th", "th", "th"][n % 10]
        return "\(n)\(suffix)"
    }
}

/// Seconds since a date, ticking once a second (still while snapshotting).
private struct ElapsedLabel: View {
    let since: Date?
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let t = since.map { max(0, (isSnapshotting ? Date() : context.date).timeIntervalSince($0)) } ?? 0
            Text(String(format: "%d:%02d", Int(t) / 60, Int(t) % 60))
                .textRole(.monoSmall, color: .textTertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - Memory warning

/// "Memory will be tight": a title, one sentence, the bar with its numbers (the one place memory figures come
/// forward, because they need a decision), then the decision. Used by `RunSurface`; usable on its own (e.g.
/// before a download).
struct MemoryWarning: View {
    let assessment: MemoryAssessment
    let modelName: String
    let onRun: () -> Void
    let onCancel: () -> Void
    var runShortcut = true
    var cancelShortcut = true

    private var wontFit: Bool { assessment.verdict == .wontFit }

    private var title: String {
        wontFit ? "\(modelName) may not fit in memory" : "Memory will be tight for \(modelName)"
    }

    private var sentence: String {
        if !assessment.wouldUnload.isEmpty {
            return "Encore will unload \(assessment.wouldUnload.joined(separator: ", ")) first, and memory may still run short."
        }
        return wontFit ? "It needs more memory than is free, so the Mac may slow down or the run may fail."
            : "It needs most of the free memory, so other apps may slow down."
    }

    var body: some View {
        let tone: Tone = wontFit ? .danger : .warning
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tone.textColor)
                    Text(title).textRole(.headline)
                }
                Text(sentence).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            }
            MemoryGauge(assessment: assessment)
            HStack(spacing: Theme.Space.xs) {
                Spacer(minLength: 0)
                Button("Not now", action: onCancel)
                    .buttonStyle(.ghost)
                    .keyboardShortcut(cancelShortcut ? KeyboardShortcut(".", modifiers: .command) : nil)
                Button(wontFit ? "Try anyway" : "Run anyway", systemImage: "play.fill", action: onRun)
                    .buttonStyle(wontFit ? .destructive : .secondary)
                    .keyboardShortcut(runShortcut ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
        }
        .padding(Theme.Space.l)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(Color.surface)
                .overlay(shape.strokeBorder(tone.color.opacity(0.3), lineWidth: 1))
        }
    }
}

/// A bar of the Mac's memory: what Encore's models hold, what this model needs, and what is free.
struct MemoryGauge: View {
    let assessment: MemoryAssessment

    var body: some View {
        let a = assessment
        let other = Double(max(0, a.memory.usedBytes - a.loadedBytes))
        let need = Double(a.requiredBytes)
        // Scale to RAM, or to the overcommitted total when the new model wouldn't fit (the overflow is the point).
        let total = max(Double(max(a.memory.physicalBytes, 1)), other + Double(a.loadedBytes) + need)
        let tone: Tone = a.verdict == .wontFit ? .danger : (a.verdict == .tight ? .warning : .success)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                HStack(spacing: 1.5) {
                    Rectangle().fill(Color.textTertiary.opacity(0.55)).frame(width: max(0, w * other / total))
                    Rectangle().fill(Color.textSecondary.opacity(0.7)).frame(width: max(0, w * Double(a.loadedBytes) / total))
                    Rectangle().fill(tone.color).frame(width: max(2, w * need / total))
                    Spacer(minLength: 0)
                }
                .frame(width: w, alignment: .leading)
                .clipShape(Capsule())
                .background(Capsule().fill(Color.surfaceSunken))
            }
            .frame(height: 6)
            HStack(spacing: Theme.Space.m) {
                legend("Needs", Self.bytes(a.requiredBytes), tone.textColor)
                legend("Free", Self.bytes(a.memory.availableBytes), .textPrimary)
                if a.loadedBytes > 0 { legend("Encore models", Self.bytes(a.loadedBytes), .textSecondary) }
                Spacer(minLength: 0)
                Text("of \(Self.bytes(a.memory.physicalBytes))").textRole(.monoSmall, color: .textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func legend(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Text(label).textRole(.caption, color: .textTertiary)
            Text(value).textRole(.monoSmall, color: color)
        }
        .fixedSize()
    }

    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        return f.string(fromByteCount: b)
    }
}
