import EncoreCore
import SwiftUI

// MARK: - Section

/// The last section of Settings: delete all app data, delete all downloaded models. Each opens its own confirmation
/// sheet that counts what will go at that moment and asks for the word "delete" to be typed before it acts.
struct ResetSection: View {
    /// Called after either action, so the screen can re-measure storage.
    var onReset: () async -> Void = {}
    /// Fixtures: show a finished action's report.
    @Environment(\.resetOutcomeFixture) private var initialOutcome

    @State private var showsAppData = false
    @State private var showsModels = false
    @State private var outcome: ResetOutcome?

    var body: some View {
        SettingsSection(title: "Reset", subtitle: "Start over. Both actions are permanent.") {
            ResetRow(title: "Delete all app data",
                     detail: "Voices, history, presets, pronunciations, settings, drafts and caches. Encore starts over as on first launch; downloaded models stay.",
                     button: "Delete app data…") { showsAppData = true }
            Hairline()
            ResetRow(title: "Delete all downloaded models",
                     detail: "Removes Encore's models from the shared Hugging Face cache — that deletes them from this Mac for every app that uses them, not just for Encore.",
                     button: "Delete models…") { showsModels = true }
            if let shown = outcome ?? initialOutcome {
                ResetOutcomeBanner(outcome: shown) { outcome = nil }
            }
        }
        .stageSheet(isPresented: $showsAppData) {
            ResetAppDataSheet { finished in
                outcome = finished
                await onReset()
            }
        }
        .stageSheet(isPresented: $showsModels) {
            ResetModelsSheet { finished in
                outcome = finished
                await onReset()
            }
        }
    }
}

private struct ResetRow: View {
    let title: String
    let detail: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textRole(.headline)
                Text(detail).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.s)
            Button(button, systemImage: "trash", action: action)
                .buttonStyle(.destructive).controlSize(.small)
                .fixedSize()
        }
    }
}

// MARK: - Outcome

extension EnvironmentValues {
    /// Fixtures: the report the Reset section shows as if an action had just finished.
    @Entry var resetOutcomeFixture: ResetOutcome? = nil
}

/// What an action did, for the banner under the two rows (and the toast).
enum ResetOutcome: Equatable {
    case appData(AppDataReset.Report)
    case models(HubRemovalResult, modelCount: Int)
    case blocked(String)

    var failures: [String] {
        switch self {
        case .appData(let r): r.failures
        case .models(let r, _): r.failures
        case .blocked: []
        }
    }

    var title: String {
        switch self {
        case .appData: failures.isEmpty ? "App data deleted" : "Some app data couldn't be deleted"
        case .models: failures.isEmpty ? "Models deleted" : "Some model files couldn't be deleted"
        case .blocked: "Nothing was deleted"
        }
    }

    var message: String {
        switch self {
        case .appData(let r):
            let i = r.removed
            var parts = [Plural.count(i.voices, "voice"), Plural.count(i.historyItems, "history item"),
                         Plural.count(i.presets, "preset"), Plural.count(i.pronunciations, "pronunciation")]
            parts[parts.count - 1] = "and " + parts[parts.count - 1]
            let summary = "Removed \(parts.joined(separator: ", ")), and reset every setting. Freed \(Bytes.file(r.bytesFreed))."
            return failures.isEmpty ? summary : summary + " " + Self.failureText(failures)
        case .models(let r, let n):
            let summary = r.removedRepos.isEmpty && r.removedWorkingCopies == 0
                ? "No models from Encore's catalog were on this Mac."
                : "Removed \(Plural.count(n, "model")) (\(Plural.count(r.removedRepos.count, "repository", "repositories"))) from the Hugging Face cache. Freed \(Bytes.file(r.bytesFreed))."
            return failures.isEmpty ? summary : summary + " " + Self.failureText(failures)
        case .blocked(let why):
            return why
        }
    }

    var toast: String {
        switch self {
        case .appData(let r): failures.isEmpty ? "App data deleted · \(Bytes.file(r.bytesFreed)) freed" : "App data partly deleted"
        case .models(let r, _): failures.isEmpty ? "Models deleted · \(Bytes.file(r.bytesFreed)) freed" : "Models partly deleted"
        case .blocked: "Nothing was deleted"
        }
    }

    private static func failureText(_ failures: [String]) -> String {
        let shown = failures.prefix(3).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: "; ")
        let more = failures.count > 3 ? " (and \(failures.count - 3) more)" : ""
        return "Still on disk — \(shown)\(more). Everything else is gone."
    }
}

private struct ResetOutcomeBanner: View {
    let outcome: ResetOutcome
    let onDismiss: () -> Void

    var body: some View {
        let tone: Tone = switch outcome {
        case .blocked: .warning
        default: outcome.failures.isEmpty ? .success : .danger
        }
        if tone == .success {
            // A finished action is information: a quiet line, not a banner.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                StatusBadge(outcome.title, tone: .success)
                Text(outcome.message).textRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: Theme.Space.s)
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .buttonStyle(.icon).controlSize(.small)
                    .help("Dismiss")
            }
        } else {
            Banner(tone, title: outcome.title, message: outcome.message, onDismiss: onDismiss) { EmptyView() }
                .textSelection(.enabled)
        }
    }
}

enum Plural {
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n.formatted()) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}

// MARK: - Typed confirmation

/// The deliberate act both resets ask for: typing a word. Return confirms once it matches.
private struct TypedConfirmation: View {
    let word: String
    @Binding var text: String
    var onSubmit: () -> Void

    var matches: Bool { Self.matches(text, word) }
    static func matches(_ text: String, _ word: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(word) == .orderedSame
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text("To confirm, type \(Text(word).font(TextRole.mono.font).foregroundStyle(Color.velvetText))")
                .textRole(.body, color: .textSecondary)
                .fixedSize()
            StageTextField(word, text: $text, symbol: matches ? "checkmark" : "keyboard", onSubmit: onSubmit)
        }
    }
}

// MARK: - Shared sheet pieces

/// A sunken box listing what an action removes, one row per kind of thing.
private struct LossList<Rows: View>: View {
    let heading: String
    var total: String?
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(heading).textRole(.eyebrow, color: .velvetText)
                Spacer()
                if let total { Text(total).textRole(.monoSmall, color: .textSecondary) }
            }
            .padding(.bottom, 6)
            rows
        }
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, 10)
        .surface(.sunken, radius: Theme.Radius.m)
    }
}

private struct LossRow: View {
    let symbol: String
    let title: String
    var detail: String?
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.textTertiary)
                .frame(width: 16)
            Text(title).textRole(.headline)
                .fixedSize()
            if let detail {
                Text(detail).textRole(.caption, color: .textTertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: Theme.Space.s)
            if let value { Text(value).textRole(.mono, color: .textSecondary).fixedSize() }
        }
        .padding(.vertical, 2.5)
    }
}

/// A model in the removal list: name over its variants.
private struct ModelCell: View {
    let symbol: String
    let name: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.textTertiary).frame(width: 14)
            Text(name).textRole(.label, color: .textPrimary).lineLimit(1)
                .layoutPriority(1)
            Text(detail).textRole(.caption, color: .textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("\(name): \(detail)")
    }
}

private struct KeepRow: View {
    let text: Text
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.mint).frame(width: 16)
            text.textRole(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The confirm button's label while measuring / working.
private struct WorkingLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.Space.s) {
            ActivityIndicator(size: 12)
            Text(text).textRole(.caption, color: .textSecondary)
        }
    }
}

private extension String {
    var abbreviatingHome: String { (self as NSString).abbreviatingWithTildeInPath }
}

// MARK: - Delete all app data

struct ResetAppDataSheet: View {
    /// Fixtures: show these counts instead of measuring.
    var preset: AppDataReset.Inventory?
    var onFinished: (ResetOutcome) async -> Void = { _ in }

    @Environment(AppDependencies.self) private var deps
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: AppDataReset.Inventory?
    @State private var typed = ""
    @State private var working = false

    private var shown: AppDataReset.Inventory? { preset ?? inventory }
    private var tokenPath: String {
        preset != nil ? "~/.cache/huggingface/token" : deps.appDataReset.tokenStore.tokenFile.path.abbreviatingHome
    }

    var body: some View {
        SheetContainer(title: "Delete all app data?",
                       subtitle: "Encore goes back to how it was on first launch. This can't be undone, and voices skip the Trash.",
                       width: 540) {
            if let i = shown {
                LossList(heading: "Deleted permanently", total: i.totalBytes > 0 ? Bytes.file(i.totalBytes) : nil) {
                    LossRow(symbol: "person.wave.2", title: "Voices", detail: voiceDetail(i),
                            value: i.voices == 0 ? "none" : i.voices.formatted())
                    LossRow(symbol: "clock.arrow.circlepath", title: "History",
                            detail: i.historyItems == 0 ? nil : "takes, transcripts and their audio · \(Bytes.file(i.historyBytes))",
                            value: i.historyItems == 0 ? "none" : i.historyItems.formatted())
                    LossRow(symbol: "slider.horizontal.3", title: "Presets", value: i.presets == 0 ? "none" : i.presets.formatted())
                    LossRow(symbol: "character.book.closed", title: "Pronunciations",
                            value: i.pronunciations == 0 ? "none" : i.pronunciations.formatted())
                    LossRow(symbol: "gearshape", title: "Settings and drafts", detail: "preferences, remembered choices, unsaved scripts")
                    LossRow(symbol: "folder", title: "Caches and scratch files", value: Bytes.file(i.otherBytes))
                    if i.hasKeychainToken {
                        LossRow(symbol: "key", title: "Hugging Face token", detail: "Encore's copy in your Keychain")
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Stays on this Mac").textRole(.eyebrow, color: .mint)
                    KeepRow(text: Text("Downloaded models (delete those separately) and files you exported."))
                    KeepRow(text: Text("The shared token file \(Text(tokenPath).font(TextRole.monoSmall.font)), so Encore signs in with it again. Sign out (above) removes it."))
                }
                TypedConfirmation(word: "delete", text: $typed, onSubmit: confirm)
            } else {
                WorkingLabel(text: "Counting what's there…").frame(height: 120)
            }
        } actions: {
            if working { WorkingLabel(text: "Stopping jobs and deleting…") }
            Button("Cancel") { dismiss() }
                .buttonStyle(.ghost)
                .keyboardShortcut(.cancelAction)
            Button("Delete app data", systemImage: "trash", action: confirm)
                .buttonStyle(.destructive)
                .disabled(!TypedConfirmation.matches(typed, "delete") || shown == nil)
        }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .task {
            guard preset == nil else { return }
            inventory = await deps.appDataReset.inventory()
        }
    }

    private func voiceDetail(_ i: AppDataReset.Inventory) -> String? {
        guard i.voices > 0 else { return nil }
        let kinds = [(i.clonedVoices, "cloned"), (i.designedVoices, "designed"), (i.importedVoices, "imported")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return (kinds + [Bytes.file(i.voiceBytes)]).joined(separator: " · ")
    }

    private func confirm() {
        guard TypedConfirmation.matches(typed, "delete"), shown != nil, !working, preset == nil else { return }
        working = true
        Task {
            let outcome: ResetOutcome
            do { outcome = .appData(try await deps.resetAppData()) } catch { outcome = .blocked(error.localizedDescription) }
            toasts.show(outcome.toast, tone: outcome.failures.isEmpty ? .success : .danger, symbol: "trash")
            await onFinished(outcome)
            working = false
            dismiss()
        }
    }
}

// MARK: - Delete all downloaded models

struct ResetModelsSheet: View {
    /// Fixtures: show this plan instead of measuring.
    var preset: ModelDownloadCenter.CatalogRemovalPlan?
    var onFinished: (ResetOutcome) async -> Void = { _ in }

    @Environment(AppDependencies.self) private var deps
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss
    @State private var plan: ModelDownloadCenter.CatalogRemovalPlan?
    @State private var typed = ""
    @State private var working = false

    private var shown: ModelDownloadCenter.CatalogRemovalPlan? { preset ?? plan }
    private var cachePath: String {
        preset != nil ? "~/.cache/huggingface/hub" : deps.downloads.downloader.store.layout.root.path.abbreviatingHome
    }

    var body: some View {
        SheetContainer(title: "Delete all downloaded models?", subtitle: "From this Mac, not just from Encore. This can't be undone.",
                       width: 540) {
            if let p = shown, p.isEmpty {
                Text("None of the models in Encore's catalog are in the Hugging Face cache, so there's nothing to delete.")
                    .textRole(.body, color: .textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Banner(.danger, title: "This deletes them for your whole computer",
                       message: "Encore keeps them in the shared Hugging Face cache (\(cachePath)). Other apps and tools that use the same models — Python scripts, the hf command-line tool, other MLX apps — lose them too.") {
                    EmptyView()
                }
            }
            if let p = shown {
                if !p.isEmpty {
                    LossList(heading: "Deleted from the cache", total: Bytes.file(p.bytes)) {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Space.l, alignment: .topLeading),
                                                GridItem(.flexible(), alignment: .topLeading)],
                                      alignment: .leading, spacing: 7) {
                                ForEach(p.models) { m in ModelCell(symbol: "cube", name: m.name, detail: variantText(m.variants)) }
                                if !p.sharedComponents.isEmpty {
                                    ModelCell(symbol: "puzzlepiece.extension", name: "Shared components",
                                              detail: p.sharedComponents.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
                                                  .joined(separator: ", "))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: 128)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(summary(p)).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                    TypedConfirmation(word: "delete", text: $typed, onSubmit: confirm)
                }
            } else {
                WorkingLabel(text: "Measuring the cache…").frame(height: 90)
            }
        } actions: {
            if working { WorkingLabel(text: "Stopping downloads and deleting…") }
            if shown?.isEmpty == true {
                Button("Close") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            } else {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.ghost)
                    .keyboardShortcut(.cancelAction)
                Button("Delete all models", systemImage: "trash", action: confirm)
                    .buttonStyle(.destructive)
                    .disabled(!TypedConfirmation.matches(typed, "delete") || shown == nil)
            }
        }
        .disabled(working)
        .interactiveDismissDisabled(working)
        .task {
            guard preset == nil else { return }
            plan = await deps.downloads.catalogRemovalPlan()
        }
    }

    private func variantText(_ variants: [ModelDownloadCenter.CatalogRemovalPlan.Model.Variant]) -> String {
        variants.map { $0.complete ? $0.label : "\($0.label) (partial)" }.joined(separator: ", ")
    }

    private func summary(_ p: ModelDownloadCenter.CatalogRemovalPlan) -> String {
        let others = p.otherRepos.count
        let left = others == 0 ? "Models that aren't from Encore's catalog are never touched."
            : "The \(Plural.count(others, "other model")) in the cache, not from Encore's catalog, \(others == 1 ? "stays" : "stay")."
        return "\(Plural.count(p.models.count, "model")), partial downloads included; downloads in progress stop first. \(left)"
    }

    private func confirm() {
        guard TypedConfirmation.matches(typed, "delete"), let p = shown, !p.isEmpty, !working, preset == nil else { return }
        working = true
        Task {
            let outcome: ResetOutcome
            do { outcome = .models(try await deps.removeAllModels(), modelCount: p.models.count) }
            catch { outcome = .blocked(error.localizedDescription) }
            toasts.show(outcome.toast, tone: outcome.failures.isEmpty ? .success : .danger, symbol: "trash")
            await onFinished(outcome)
            working = false
            dismiss()
        }
    }
}
