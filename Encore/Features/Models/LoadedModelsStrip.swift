import EncoreCore
import SwiftUI

/// What's in memory right now: one line for the total (with Unload all), then one line per loaded model with its
/// memory, whether it is working or idle (and when it will unload itself), and an eject control.
/// Draws nothing while no model is loaded.
struct LoadedModelsStrip: View {
    /// Kept so existing callers compile; the strip no longer shows disk usage.
    var showsDiskUsage = false

    @Environment(RuntimeStatus.self) private var status
    @Environment(EncoreService.self) private var service

    var body: some View {
        if !status.loaded.isEmpty {
            VStack(spacing: 0) {
                header
                ForEach(status.loaded) { model in
                    Hairline()
                    LoadedModelRow(model: model) {
                        Task { await service.runtime.unload(modelID: model.modelID) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .surface()
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("In memory").textRole(.headline)
                Text("\(Bytes.memory(status.loadedBytes)) of \(Bytes.memory(status.memory.physicalBytes))")
                    .textRole(.monoSmall, color: .textTertiary)
                    .lineLimit(1)
                    .help("\(Bytes.memory(status.memory.availableBytes)) of this Mac's memory is free right now.")
            }
            Spacer(minLength: Theme.Space.s)
            if status.loaded.count > 1 {
                Button("Unload all") { Task { await service.runtime.unloadAll() } }
                    .buttonStyle(.ghost)
                    .controlSize(.small)
            }
        }
        .frame(minHeight: Theme.ControlHeight.small)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.xs)
    }
}

private struct LoadedModelRow: View {
    let model: LoadedModel
    let unload: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(model.modelName).textRole(.headline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Theme.Space.s)
            Text(Bytes.memory(model.memoryBytes)).textRole(.mono, color: .textSecondary)
                .frame(minWidth: 64, alignment: .trailing)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                stateBadge(now: context.date)
            }
            .frame(width: 170, alignment: .trailing)
            Button("Unload \(model.modelName)", systemImage: "eject") { unload() }
                .buttonStyle(.icon)
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .disabled(model.isBusy)
                .help(model.isBusy ? "Working. It can be unloaded when the job finishes." : "Unload now")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func stateBadge(now: Date) -> some View {
        if model.isBusy {
            StatusBadge("Working", pulsing: true)
        } else if let at = model.unloadsAt {
            let left = at.timeIntervalSince(now)
            Text(left > 30 ? "Idle · unloads in \(Durations.short(left))" : "Idle · unloading soon")
                .textRole(.caption, color: .textTertiary)
                .lineLimit(1)
        } else {
            Text("Idle · stays loaded").textRole(.caption, color: .textTertiary)
                .lineLimit(1)
        }
    }
}
