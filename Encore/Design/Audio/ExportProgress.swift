import EncoreCore
import SwiftUI

/// Audio exports in flight, shown as a progress card above the toasts while they encode. Every export goes
/// through `track(_:_:)`: a short one never shows a bar (it has to outlast `grace` first), and a bar that did
/// appear stays at least `minimumShown`, so nothing flashes. Lives in `AppDependencies` (`deps.exports`).
///
///     try await exports.track("Take 3.mp3") { progress in
///         try await AudioExporter.convert(source, to: url, format: .mp3, progress: progress)
///     }
@MainActor @Observable
final class ExportProgressCenter {
    struct Job: Identifiable, Equatable {
        let id: UUID
        var title: String
        /// 0…1, from the encoder.
        var fraction: Double
    }

    /// Exports that have run past the grace period, oldest first.
    private(set) var visible: [Job] = []

    static let grace: Duration = .milliseconds(400)
    static let minimumShown: Duration = .milliseconds(600)

    private final class Entry {
        var job: Job
        var cancel: () -> Void = {}
        var shownAt: ContinuousClock.Instant?
        init(job: Job) { self.job = job }
    }
    @ObservationIgnored private var entries: [UUID: Entry] = [:]

    /// Runs `operation`, handing it a progress callback (callable from any thread), and shows a bar for it if it
    /// takes longer than `grace`. Returns or throws what the operation does; canceling from the card throws
    /// `CancellationError`.
    func track<T: Sendable>(_ title: String,
                            _ operation: @escaping @MainActor (_ progress: @escaping ExportProgress) async throws -> T) async throws -> T {
        let id = UUID()
        let entry = Entry(job: Job(id: id, title: title, fraction: 0))
        entries[id] = entry
        let relay = ProgressRelay { [weak self] fraction in self?.update(id, fraction) }
        let work = Task { try await operation(relay.report) }
        entry.cancel = { work.cancel() }
        let reveal = Task { [weak self] in
            try? await Task.sleep(for: ExportProgressCenter.grace)
            guard !Task.isCancelled else { return }
            self?.reveal(id)
        }
        let result = await work.result
        reveal.cancel()
        if let shownAt = entry.shownAt {
            if case .success = result { update(id, 1) }
            let shown = ContinuousClock.now - shownAt
            if shown < Self.minimumShown { try? await Task.sleep(for: Self.minimumShown - shown) }
        }
        entries[id] = nil
        if visible.contains(where: { $0.id == id }) {
            withStageAnimation { visible.removeAll { $0.id == id } }
        }
        return try result.get()
    }

    /// Stops an export (the card's cancel button). The partial file is never left behind.
    func cancel(_ id: UUID) { entries[id]?.cancel() }

    private func reveal(_ id: UUID) {
        guard let entry = entries[id], entry.shownAt == nil else { return }
        entry.shownAt = .now
        withStageAnimation(Theme.Motion.entrance) { visible.append(entry.job) }
    }

    private func update(_ id: UUID, _ fraction: Double) {
        guard let entry = entries[id] else { return }
        entry.job.fraction = max(entry.job.fraction, min(max(fraction, 0), 1))
        if let i = visible.firstIndex(where: { $0.id == id }) { visible[i].fraction = entry.job.fraction }
    }

    #if DEBUG
    /// Snapshot fixtures: a card frozen at `fraction`.
    func debugShow(_ title: String, fraction: Double) {
        visible.append(Job(id: UUID(), title: title, fraction: fraction))
    }
    #endif
}

/// Carries encoder progress (any thread) to the main actor, at most every half percent.
private nonisolated final class ProgressRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let deliver: @MainActor (Double) -> Void

    init(_ deliver: @escaping @MainActor (Double) -> Void) { self.deliver = deliver }

    var report: ExportProgress { { [self] fraction in send(fraction) } }

    private func send(_ fraction: Double) {
        let due = lock.withLock { () -> Bool in
            guard fraction >= 1 || fraction - last >= 0.005 else { return false }
            last = fraction
            return true
        }
        guard due else { return }
        let deliver = self.deliver
        Task { @MainActor in deliver(fraction) }
    }
}

// MARK: - View

extension View {
    /// Draws the export cards from the environment's `ExportProgressCenter` at the bottom of this view, above any
    /// toast. Apply after `toastOverlay`.
    func exportProgressOverlay() -> some View { modifier(ExportProgressOverlay()) }
}

private struct ExportProgressOverlay: ViewModifier {
    @Environment(ExportProgressCenter.self) private var center: ExportProgressCenter?
    @Environment(ToastCenter.self) private var toasts: ToastCenter?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let center, !center.visible.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    ForEach(center.visible) { job in
                        ExportProgressCard(job: job) { center.cancel(job.id) }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Toasts sit at the bottom (36 pt tall); keep clear of one.
                .padding(.bottom, Theme.Space.xl + (toasts?.current != nil ? 36 + Theme.Space.s : 0))
                .stageAnimation(Theme.Motion.standard, value: toasts?.current != nil)
            }
        }
    }
}

/// One export: what's being written, how far along, and a way to stop it.
struct ExportProgressCard: View {
    let job: ExportProgressCenter.Job
    var onCancel: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.tungsten)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text("Exporting “\(job.title)”")
                        .font(.ui(12.5, weight: .medium)).foregroundStyle(.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: Theme.Space.s)
                    Text(job.fraction.formatted(.percent.precision(.fractionLength(0))))
                        .textRole(.monoSmall, color: .textSecondary)
                        .monospacedDigit()
                }
                ProgressBar(value: job.fraction)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Exporting \(job.title), \(Int((job.fraction * 100).rounded())) percent")
            .accessibilityAddTraits(.updatesFrequently)
            if let onCancel {
                Button("Cancel export", systemImage: "xmark", action: onCancel)
                    .buttonStyle(.icon)
                    .controlSize(.small)
                    .help("Stop this export")
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.s)
        .padding(.vertical, Theme.Space.s + 2)
        .frame(width: 340)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(Color.surfaceRaised).overlay(shape.strokeBorder(Color.hairlineStrong, lineWidth: 1))
        }
        .elevation()
        .accessibilityElement(children: .contain)
    }
}
