import EncoreCore
import SwiftUI

/// Voice design: describe a voice and give it a line to say, audition several voices for it, keep the one you
/// like as a library voice, and hear it speak.
struct DesignScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Design") { DesignModel(deps: deps) }
        DesignStage(model: model)
    }
}

/// The screen's layout. Wide: the form card on the left (its fields scroll, Audition stays pinned at the bottom)
/// and the auditions on the right. Narrow: one scrolling column (the form folds to a summary once auditions
/// exist) above a pinned Audition bar.
struct DesignStage: View {
    @Bindable var model: DesignModel
    @State private var width: CGFloat = 900
    @State private var briefOpen = false

    private var wide: Bool { width >= 720 }
    private var formWidth: CGFloat { min(400, max(320, width * 0.42)) }

    var body: some View {
        ScreenScaffold(.design, scrolls: false) {
            if !model.shelf.hasScanned {
                Color.clear.frame(height: 1)
            } else if model.needsFirstModel {
                FirstModelStage(symbol: "wand.and.stars", title: "No voice designer on this Mac",
                                message: "Designing a voice from a description needs a model that can do it. Qwen3-TTS VoiceDesign is the one to start with.",
                                starterIDs: ["qwen3-tts-voicedesign", "voxcpm2", "omnivoice"])
            } else if wide {
                wideLayout
            } else {
                narrowLayout
            }
        } actions: {
            if !model.auditions.isEmpty && !model.needsFirstModel {
                Button("Clear auditions", systemImage: "xmark.circle") { model.clear() }
                    .buttonStyle(.ghost)
                    .disabled(model.runner.isBusy)
                    .help("Delete the auditions you didn't keep and clear the list. Kept voices stay in your library.")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.Space.screenInset } action: { width = $0 }
        .task { await model.prepare() }
        .onChange(of: model.runner.isRunning) { _, running in if running { withStageAnimation { briefOpen = false } } }
    }

    // MARK: Wide

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: Theme.Space.xl) {
            BriefCard(model: model).frame(width: formWidth)
            auditionsPane.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var auditionsPane: some View {
        if model.auditions.isEmpty && !model.runner.isRunning {
            EmptyBench()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                AuditionsHeader(model: model)
                ScrollView {
                    AuditionsList(model: model)
                        .padding(.bottom, Theme.Space.l)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    // MARK: Narrow

    /// Once auditions are on stage (or running) the form folds to a one-line summary until Edit opens it.
    private var folded: Bool { (!model.auditions.isEmpty || model.runner.isBusy) && !briefOpen }

    private var narrowLayout: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    if folded {
                        BriefSummary(model: model) { withStageAnimation { briefOpen = true } }
                    } else {
                        BriefFields(model: model,
                                    onFold: model.auditions.isEmpty ? nil : { withStageAnimation { briefOpen = false } })
                            .padding(Theme.Space.l)
                            .surface(.card)
                    }
                    if model.auditions.isEmpty && !model.runner.isRunning {
                        EmptyBench()
                    } else {
                        AuditionsHeader(model: model)
                        AuditionsList(model: model)
                    }
                }
                .padding(.bottom, Theme.Space.s)
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            BriefFooter(model: model)
                .padding(Theme.Space.l)
                .surface(.card)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Form

/// The form as a card: the fields scroll when the window is short; the action row is pinned at the bottom.
/// The card hugs its content when there's room.
private struct BriefCard: View {
    @Bindable var model: DesignModel
    @State private var fieldsHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                BriefFields(model: model)
                    .padding(Theme.Space.l)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldsHeight = $0 }
            }
            .scrollIndicators(.automatic)
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: fieldsHeight)
            Hairline()
            BriefFooter(model: model)
                .padding(Theme.Space.l)
        }
        .surface(.card)
    }
}

/// Narrow layouts with auditions on stage: the description in a line or two, and Edit.
private struct BriefSummary: View {
    @Bindable var model: DesignModel
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text("“\(model.description)”")
                .textRole(.body, color: .textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit", systemImage: "pencil", action: onEdit)
                .buttonStyle(.ghost).controlSize(.small)
                .help("Edit the description, the line and the model")
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }
}

/// Every field of the form, top to bottom: the description and its examples, the line, then the model,
/// language, how many, and the model's settings.
private struct BriefFields: View {
    @Bindable var model: DesignModel
    var onFold: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Describe the voice").textRole(.label, color: .textSecondary)
                    Spacer(minLength: 0)
                    if let onFold {
                        Button("Fold", systemImage: "chevron.up", action: onFold).buttonStyle(.ghost).controlSize(.small)
                    }
                }
                ScriptEditor(text: $model.description,
                             placeholder: "Age, timbre, pace, accent, mood…",
                             minHeight: 96, showsStats: false)
                examples
                if let problem = model.descriptionProblem {
                    Text(problem).textRole(.caption, color: Tone.warning.textColor).fixedSize(horizontal: false, vertical: true)
                } else if let hint = model.descriptionHint {
                    Text(hint).textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("What they'll say").textRole(.label, color: .textSecondary)
                ScriptEditor(text: $model.sampleText, placeholder: "A line or two for each audition…", minHeight: 72, showsStats: false)
            }
            .help("The voice you keep is saved with this line as its reference transcript. A sentence or two (5–15 s) works best.")
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ModelPicker(task: .tts, requires: .voiceDesign, feature: .voiceDesign, selection: $model.choice, panelWidth: 420)
                HStack(alignment: .bottom, spacing: Theme.Space.s) {
                    if let m = model.manifest, m.languages.count > 1 {
                        LanguagePicker(manifest: m, selection: $model.language).fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                        Text("How many").textRole(.label, color: .textSecondary)
                        SegmentedControl(selection: $model.count, options: [1, 2, 3, 4, 6]) { "\($0)" }.controlSize(.small)
                    }
                    .help("How many different voices each audition makes")
                }
                if let m = model.manifest, !m.parameters.isEmpty {
                    AdvancedDisclosure("Model settings", isExpanded: $model.showSettings) {
                        ParameterPanel(manifest: m, values: $model.parameters)
                    }
                }
            }
        }
    }

    private var examples: some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Text("Start from").textRole(.caption, color: .textTertiary)
                .frame(height: 22)
                .fixedSize()
            FlowRow(spacing: 6, lineSpacing: 6) {
                ForEach(model.examples, id: \.title) { ex in
                    Chip(ex.title, isSelected: Binding(
                        get: { model.description == ex.text },
                        set: { on in if on { withStageAnimation(Theme.Motion.quick) { model.description = ex.text } } }))
                        .help(ex.text)
                }
            }
        }
    }
}

/// What sits under the form, always visible: a problem that needs action (an error, a model that isn't
/// downloaded), then Audition.
private struct BriefFooter: View {
    @Bindable var model: DesignModel
    @Environment(Router.self) private var router

    private var notDownloaded: ModelManifest? {
        guard let m = model.manifest, model.shelf.hasScanned, !model.isDownloaded else { return nil }
        return m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let error = model.runner.error {
                ServiceErrorBanner(error: error, onDismiss: { model.runner.error = nil }, onRetry: model.run)
            } else if let m = notDownloaded {
                Banner(.warning, title: "\(m.name) isn't downloaded yet") {
                    Button("Get it in Models") { router.go(.models) }
                        .buttonStyle(.secondary).controlSize(.small)
                }
            }
            RunSurface(runner: model.runner, title: "Audition", systemImage: "wand.and.stars",
                       blockedReason: blockedReason, idleNote: nil, action: model.run)
        }
    }

    /// The model's reason, except that a missing download is already named in the banner above.
    private var blockedReason: String? {
        guard model.runner.error == nil else { return nil }
        if notDownloaded != nil { return "Download the model first." }
        return model.blockedReason
    }
}

// MARK: - Auditions

/// Before any audition: the one thing to know.
private struct EmptyBench: View {
    var body: some View {
        EmptyState(symbol: "wand.and.stars", title: "The auditions start here",
                   message: "Every audition is a different voice, not another take of the same one. The one you keep becomes a voice in your library.")
    }
}

private struct AuditionsHeader: View {
    @Bindable var model: DesignModel

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Auditions").textRole(.section)
            if !model.auditions.isEmpty { CountBadge(model.auditions.count) }
            Spacer(minLength: Theme.Space.s)
            if !model.unsaved.isEmpty {
                Button("Discard unkept", systemImage: "trash") { model.discardUnsaved() }
                    .buttonStyle(.ghost).controlSize(.small)
                    .disabled(model.runner.isBusy)
                    .help("Delete every audition you didn't keep")
            }
            Button("More like this", systemImage: "sparkles") { model.moreLikeThis() }
                .buttonStyle(.secondary).controlSize(.small)
                .disabled(model.runner.isBusy || model.blockedReason != nil)
                .help("Audition \(model.count) more voices for the same description")
        }
    }
}

/// Newest round first. Round labels appear only when there's more than one round.
private struct AuditionsList: View {
    @Bindable var model: DesignModel

    private var rounds: [Int] {
        var r = Array(Set(model.auditions.map(\.round)))
        if model.runner.isRunning, model.round > 0, !r.contains(model.round) { r.append(model.round) }
        return r.sorted(by: >)
    }

    var body: some View {
        let rounds = self.rounds
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            ForEach(rounds, id: \.self) { round in
                roundSection(round, labeled: rounds.count > 1)
            }
        }
    }

    private func roundSection(_ round: Int, labeled: Bool) -> some View {
        let items = model.auditions.filter { $0.round == round }
        let pending = round == model.round ? model.pendingInRound : 0
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            if labeled {
                HStack(spacing: Theme.Space.s) {
                    Text("Round \(round)").textRole(.eyebrow)
                    Hairline()
                }
            }
            ForEach(items) { a in AuditionCard(model: model, audition: a) }
            ForEach(0..<pending, id: \.self) { i in
                PendingAudition(number: items.count + i + 1, isNext: i == 0)
            }
        }
    }
}

/// A candidate still being made. The run's stage is shown once, by Audition's run surface.
private struct PendingAudition: View {
    let number: Int
    let isNext: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Audition \(number)").textRole(.headline, color: .textTertiary)
            HStack(spacing: Theme.Space.s) {
                if isNext {
                    ActivityIndicator(size: 14).frame(width: 24)
                } else {
                    Color.clear.frame(width: 24, height: 14)
                }
                Waveform(samples: Waveform.placeholder(count: 64, seed: number), progress: 0)
                    .frame(height: 22)
                    .opacity(0.2)
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: 38)
            .surface(.sunken, radius: Theme.Radius.m)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isNext ? "Audition \(number), in progress" : "Audition \(number), queued")
    }
}

private struct AuditionCard: View {
    @Bindable var model: DesignModel
    let audition: DesignModel.Audition
    @Environment(VoiceLibrary.self) private var library

    private var isKeeping: Bool { model.keeping == audition.id }
    private var title: String { audition.savedVoice?.name ?? "Audition \(audition.number)" }

    /// Engineering detail for the tooltip: the model and the seed.
    private var details: String {
        var parts = [model.shelf.service.catalog.model(audition.candidate.modelID)?.name ?? audition.candidate.modelID]
        if let seed = audition.candidate.seed { parts.append("seed \(seed)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(title).textRole(.headline).lineLimit(1)
                    .help(details)
                if audition.savedVoice != nil {
                    StatusBadge("Kept", tone: .success)
                }
                Spacer(minLength: 0)
            }
            WaveformPlayer(url: URL(fileURLWithPath: audition.candidate.audioPath),
                           title: title,
                           subtitle: String(format: "%.1f s", audition.candidate.duration),
                           style: .compact)
                .accessory { accessory }
            if isKeeping {
                keepForm
                    .padding(.top, Theme.Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if audition.savedVoice != nil, model.tryoutFor == audition.id {
                VoiceTryoutPanel(tryout: model.tryout)
                    .padding(Theme.Space.l)
                    .surface(.card)
                    .padding(.top, Theme.Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder private var accessory: some View {
        if audition.savedVoice == nil {
            Button("Keep", systemImage: "person.crop.circle.badge.plus") { withStageAnimation { model.beginKeeping(audition.id) } }
                .buttonStyle(.secondary).controlSize(.small)
                .disabled(isKeeping)
                .help("Name this voice and save it to your library")
            Button("Discard", systemImage: "xmark") { model.discard(audition.id) }
                .buttonStyle(.icon).controlSize(.small).help("Discard this audition")
        }
    }

    private var keepForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Name").textRole(.label, color: .textSecondary)
                TextField(model.suggestedName, text: $model.keepName, prompt: Text(model.suggestedName).foregroundStyle(Color.textTertiary))
                    .textFieldStyle(.plain)
                    .textRole(.heading)
                    .padding(.horizontal, 10).frame(height: 36)
                    .surface(.sunken, radius: Theme.Radius.s)
                    .onSubmit { Task { await model.keep() } }
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Tags").textRole(.label, color: .textSecondary)
                TagEditor(tags: $model.keepTags, suggestions: library.allTags)
            }
            if let e = model.saveError {
                Text("The voice wasn't saved. \(e)")
                    .textRole(.caption, color: .velvetText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.s) {
                Button(model.isSaving ? "Saving…" : "Save to library", systemImage: "checkmark") { Task { await model.keep() } }
                    .buttonStyle(.primary)
                    .disabled(model.isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { withStageAnimation { model.keeping = nil } }.buttonStyle(.ghost)
            }
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }
}
