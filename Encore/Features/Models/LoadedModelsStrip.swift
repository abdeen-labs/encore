import EncoreCore
import SwiftUI

/// What's in memory right now: each loaded model with its memory, runtime, busy/idle and when it will
/// unload itself, plus unload / unload all. Also used by Settings › Memory.
struct LoadedModelsStrip: View {
    var showsDiskUsage = true

    @Environment(RuntimeStatus.self) private var status
    @Environment(EncoreService.self) private var service
    @Environment(AppSettings.self) private var settings
    @Environment(ModelDownloadCenter.self) private var downloads

    var body: some View {
        Card(padding: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text("In memory").textRole(.eyebrow)
                Spacer(minLength: Theme.Space.s)
                MemoryMeter(memory: status.memory, loadedBytes: status.loadedBytes)
                if showsDiskUsage {
                    Text("·").foregroundStyle(.textTertiary)
                    Text(downloads.totalBytesOnDisk > 0 ? "\(Bytes.file(downloads.totalBytesOnDisk)) on disk" : "no models on disk")
                        .textRole(.monoSmall, color: .textTertiary).lineLimit(1)
                }
                if status.loaded.count > 1 {
                    Button("Unload all") { Task { await service.runtime.unloadAll() } }
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .padding(.top, Theme.Space.m)
            .padding(.bottom, status.loaded.isEmpty ? Theme.Space.xs : Theme.Space.m)

            if status.loaded.isEmpty {
                Text(emptyMessage).textRole(.caption)
                    .padding(.horizontal, Theme.Space.l)
                    .padding(.bottom, Theme.Space.m)
            } else {
                VStack(spacing: 0) {
                    ForEach(status.loaded) { model in
                        HLine().stroke(Color.hairline).frame(height: 1)
                        LoadedModelRow(model: model) {
                            Task { await service.runtime.unload(modelID: model.modelID) }
                        }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        let idle = settings.idleUnloadMinutes
        let unload = idle == 0 ? "and stay loaded until you unload them" : "and unload after \(idle) minutes idle"
        return "Nothing loaded. Models load on first use \(unload)."
    }
}

private struct LoadedModelRow: View {
    let model: LoadedModel
    let unload: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.modelName).font(.ui(13, weight: .semibold)).foregroundStyle(.textPrimary).lineLimit(1)
                Text(model.variantLabel).textRole(.monoSmall, color: .textTertiary)
                Text("· \(model.runtime.displayName)").textRole(.caption, color: .textTertiary).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            Text(Bytes.memory(model.memoryBytes)).textRole(.mono, color: .textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                stateBadge(now: context.date)
            }
            .frame(width: 160, alignment: .trailing)
            Button("Unload \(model.modelName)", systemImage: "eject") { unload() }
                .buttonStyle(.icon)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .disabled(model.isBusy)
                .help(model.isBusy ? "Busy — it can be unloaded when the job finishes" : "Unload now")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 5)
    }

    @ViewBuilder private func stateBadge(now: Date) -> some View {
        if model.isBusy {
            StatusBadge("Working", tone: .accent, pulsing: true)
        } else if let at = model.unloadsAt {
            let left = at.timeIntervalSince(now)
            Text(left > 30 ? "Idle · unloads in \(Durations.short(left))" : "Idle · unloading soon")
                .textRole(.caption, color: .textTertiary)
        } else {
            Text("Idle · stays loaded").textRole(.caption, color: .textTertiary)
        }
    }
}

/// "48 GB RAM · 9.6 GB loaded" with a slim bar: Encore's models over the rest of the Mac's use.
struct MemoryMeter: View {
    let memory: SystemMemory
    let loadedBytes: Int64

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            GeometryReader { geo in
                let total = max(Double(memory.physicalBytes), 1)
                let used = Double(memory.usedBytes) / total
                let mine = min(Double(loadedBytes) / total, used)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.surfaceSunken)
                    Capsule().fill(Color.textTertiary.opacity(0.45)).frame(width: geo.size.width * used)
                    Capsule().fill(Color.tungsten).frame(width: geo.size.width * mine)
                }
            }
            .frame(width: 64, height: 4)
            Text(loadedBytes > 0 ? "\(Bytes.memory(loadedBytes)) loaded · \(Bytes.memory(memory.availableBytes)) free"
                                 : "\(Bytes.memory(memory.availableBytes)) free of \(Bytes.memory(memory.physicalBytes))")
                .textRole(.monoSmall, color: .textTertiary)
                .lineLimit(1)
        }
        .help("Tungsten: Encore's models. Gray: everything else on this Mac.")
    }
}
