import EncoreCore
import SwiftUI

/// The rail's activity lamp: while anything in the app is running or waiting for the GPU (`RuntimeStatus.jobs`),
/// a small card at the foot of the rail says what, on which model, the stage, progress and how many wait behind
/// it. Idle, it isn't there at all. Clicking it lists every job, each with a way back to the screen it came from.
struct RailActivity: View {
    /// Short windows: drop the title line (it's in the tooltip and the job list).
    var compact = false
    @Environment(RuntimeStatus.self) private var status
    @Environment(Router.self) private var router
    @State private var showsJobs = false
    @State private var isHovered = false

    var body: some View {
        if let job = status.runningJob ?? status.jobs.first {
            Button { showsJobs.toggle() } label: {
                card(job, queued: status.queuedJobs.count - (job.state == .queued ? 1 : 0))
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .popover(isPresented: $showsJobs, arrowEdge: .trailing) {
                JobList(jobs: status.jobs) { section in
                    showsJobs = false
                    router.go(section)
                }
                .preferredColorScheme(.dark)
            }
            .help("\(job.title) · \(status.jobs.count == 1 ? "1 job" : "\(status.jobs.count) jobs"): click for details")
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText(job))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func card(_ job: JobStatus, queued: Int) -> some View {
        let running = job.state == .running
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if running {
                    ActivityIndicator(size: 11)
                } else {
                    Image(systemName: "hourglass").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Color.textTertiary)
                        .frame(width: 11)
                }
                Text(JobKindStyle.verb(job.kind, running: running))
                    .font(.ui(9.5, weight: .bold)).tracking(1.2).textCase(.uppercase)
                    .foregroundStyle(running ? Color.tungsten : .textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let p = job.progress, running {
                    Text("\(Int((p * 100).rounded()))%").font(.mono(10)).foregroundStyle(.textSecondary).monospacedDigit()
                }
            }
            if !compact {
                Text(job.title).font(.ui(12, weight: .semibold)).foregroundStyle(.textPrimary).lineLimit(1)
            }
            Text([job.modelName, job.stage].compactMap { $0 }.joined(separator: " · "))
                .font(.ui(10.5)).foregroundStyle(.textTertiary).lineLimit(1)
            HStack(spacing: 6) {
                ProgressBar(value: running ? job.progress : nil, tone: running ? .accent : .neutral, height: 2.5)
                if queued > 0 {
                    Text("+\(queued) queued").font(.mono(9.5)).foregroundStyle(.textSecondary).fixedSize()
                }
            }
            .frame(height: 11)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(Color.surfaceSunken)
                .overlay(shape.strokeBorder(isHovered || showsJobs ? Color.tungsten.opacity(0.4) : Color.hairline, lineWidth: 1))
        }
        .contentShape(Rectangle())
        .stageAnimation(Theme.Motion.quick, value: isHovered)
    }

    private func accessibilityText(_ job: JobStatus) -> String {
        var parts = [JobKindStyle.verb(job.kind, running: job.state == .running), job.title, job.modelName]
        if let s = job.stage { parts.append(s) }
        if let p = job.progress { parts.append("\(Int(p * 100)) percent") }
        let queued = status.queuedJobs.count
        if queued > 0 { parts.append("\(queued) queued") }
        return parts.joined(separator: ", ")
    }
}

/// Every job, running first then the queue in order, each with a jump to its screen.
private struct JobList: View {
    let jobs: [JobStatus]
    let onGo: (AppSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeading(title: "Activity", count: jobs.count)
                .padding(.horizontal, Theme.Space.xs)
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 { Rectangle().fill(Color.hairline).frame(height: 1).padding(.horizontal, Theme.Space.m) }
                row(job, position: index)
            }
            Text("Each screen's Stop button cancels its own job.")
                .textRole(.caption, color: .textTertiary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.s)
        }
        .padding(.vertical, Theme.Space.xs)
        .frame(width: 300)
        .background(Color.surfaceRaised)
    }

    private func row(_ job: JobStatus, position: Int) -> some View {
        let running = job.state == .running
        let section = JobKindStyle.section(job.kind)
        return HStack(alignment: .top, spacing: Theme.Space.s) {
            Group {
                if running { ActivityIndicator(size: 12) }
                else { Text("\(position)").font(.mono(10, weight: .semibold)).foregroundStyle(.textTertiary) }
            }
            .frame(width: 14, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).textRole(.headline).lineLimit(1)
                Text([JobKindStyle.verb(job.kind, running: running), job.modelName, job.runtime?.displayName]
                    .compactMap { $0 }.joined(separator: " · "))
                    .textRole(.caption, color: .textTertiary).lineLimit(1)
                if running {
                    if let stage = job.stage { Text(stage).textRole(.caption, color: .textSecondary).lineLimit(1) }
                    ProgressBar(value: job.progress, height: 3).padding(.top, 2)
                } else {
                    Text("Waiting since \(job.enqueuedAt.formatted(date: .omitted, time: .shortened))")
                        .textRole(.caption, color: .textTertiary)
                }
            }
            Spacer(minLength: 4)
            Button("Open \(section.title)", systemImage: "arrow.right") { onGo(section) }
                .labelStyle(.iconOnly)
                .buttonStyle(.icon)
                .controlSize(.small)
                .help("Go to \(section.title)")
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }
}

/// How each kind of job is named and where it lives.
enum JobKindStyle {
    static func verb(_ kind: JobKind, running: Bool) -> String {
        guard running else { return "Queued" }
        switch kind {
        case .speech: return "Performing"
        case .conversation: return "Staging"
        case .voiceConversion: return "Changing voice"
        case .voiceDesign: return "Designing"
        case .transcription: return "Transcribing"
        case .referenceTranscription: return "Transcribing clip"
        }
    }

    static func section(_ kind: JobKind) -> AppSection {
        switch kind {
        case .speech: .studio
        case .conversation: .conversations
        case .voiceConversion: .changer
        case .voiceDesign: .design
        case .transcription: .transcribe
        case .referenceTranscription: .clone
        }
    }
}
