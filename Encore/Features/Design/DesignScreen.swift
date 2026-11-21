import EncoreCore
import SwiftUI

/// Voice design: write a brief (a description and a line to say), audition several voices for it, keep the one
/// you like as a library voice, and hear it speak.
struct DesignScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Design") { DesignModel(deps: deps) }
        DesignStage(model: model)
    }
}

struct DesignStage: View {
    @Bindable var model: DesignModel
    @State private var width: CGFloat = 900
    @State private var briefOpen = false

    private var wide: Bool { width >= 800 }

    var body: some View {
        ScreenScaffold(.design) {
            if !model.shelf.hasScanned {
                Color.clear.frame(height: 1)
            } else if model.needsFirstModel {
                DesignFirstRun(model: model)
            } else if wide {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    BriefCard(model: model).frame(width: min(400, max(340, width * 0.4)))
                    AuditionsColumn(model: model).frame(maxWidth: .infinity)
                }
            } else if !model.auditions.isEmpty || model.runner.isBusy, !briefOpen {
                // Narrow: once auditions exist they take the stage and the brief folds to a summary.
                BriefSummary(model: model) { withStageAnimation { briefOpen = true } }
                AuditionsColumn(model: model)
            } else {
                BriefCard(model: model, onFold: model.auditions.isEmpty ? nil : { withStageAnimation { briefOpen = false } })
                AuditionsColumn(model: model)
            }
        } actions: {
            if !model.auditions.isEmpty {
                Button("Clear auditions", systemImage: "xmark.circle") { model.clear() }
                    .buttonStyle(.ghost)
                    .disabled(model.runner.isBusy)
                    .help("Delete the auditions you didn't keep and clear the bench. Kept voices stay in your library.")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.Space.screenInset } action: { width = $0 }
        .task { await model.prepare() }
        .onChange(of: model.runner.isRunning) { _, running in if running { withStageAnimation { briefOpen = false } } }
    }
}

// MARK: - Brief

/// Narrow layouts with auditions on stage: the brief in one line, with Edit and Audition.
private struct BriefSummary: View {
    @Bindable var model: DesignModel
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("The brief").textRole(.eyebrow, color: .tungsten.opacity(0.8))
                Spacer()
                Button("Edit brief", systemImage: "pencil", action: onEdit).buttonStyle(.ghost).controlSize(.small)
            }
            Text("“\(model.description)”")
                .font(.display(15, italic: true)).foregroundStyle(.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            RunSurface(runner: model.runner, title: "Audition", systemImage: "wand.and.stars",
                       blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                       idleNote: model.manifest.map { "\(model.count) voice\(model.count == 1 ? "" : "s") · \($0.name)" }, action: model.run)
            if let error = model.runner.error {
                ServiceErrorBanner(error: error, onDismiss: { model.runner.error = nil }, onRetry: model.run)
            }
        }
        .padding(Theme.Space.l)
        .surface(.card)
    }
}

private struct BriefCard: View {
    @Bindable var model: DesignModel
    var onFold: (() -> Void)?
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text("The brief").textRole(.eyebrow, color: .tungsten.opacity(0.8))
                    Spacer()
                    if let onFold {
                        Button("Fold", systemImage: "chevron.up", action: onFold).buttonStyle(.ghost).controlSize(.small)
                    }
                }
                ScriptEditor(text: $model.description,
                             placeholder: "Describe the voice: age, timbre, pace, accent, mood…",
                             minHeight: 104, showsStats: false)
                examples
                if let problem = model.descriptionProblem {
                    Text(problem).textRole(.caption, color: .footlight).fixedSize(horizontal: false, vertical: true)
                } else if let hint = model.descriptionHint {
                    Text(hint).textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("What they'll say").textRole(.label, color: .textSecondary)
                ScriptEditor(text: $model.sampleText, placeholder: "A line or two for each audition…", minHeight: 84, showsStats: false)
                Text("The voice you keep is saved with this line as its reference transcript. A sentence or two (5–15 s) works best.")
                    .textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ModelPicker(task: .tts, requires: .voiceDesign, feature: .voiceDesign, selection: $model.choice, panelWidth: 420)
                HStack(spacing: Theme.Space.s) {
                    if let m = model.manifest, m.languages.count > 1 {
                        LanguagePicker(manifest: m, selection: $model.language).fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Auditions").textRole(.label, color: .textSecondary)
                        SegmentedControl(selection: $model.count, options: [1, 2, 3, 4, 6]) { "\($0)" }.controlSize(.small)
                    }
                }
                if let m = model.manifest, !m.parameters.isEmpty {
                    AdvancedDisclosure("Model settings", isExpanded: $model.showSettings) {
                        ParameterPanel(manifest: m, values: $model.parameters)
                    }
                }
            }
            notices
            RunSurface(runner: model.runner, title: "Audition",
                       systemImage: "wand.and.stars",
                       blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                       idleNote: idleNote, action: model.run)
        }
        .padding(Theme.Space.l)
        .surface(.card)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var idleNote: String? {
        guard let m = model.manifest else { return nil }
        return "\(model.count) voice\(model.count == 1 ? "" : "s") · \(m.name)"
    }

    private var examples: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text("Start from").textRole(.caption, color: .textTertiary).fixedSize()
            FlowRow(spacing: 5, lineSpacing: 5) {
                ForEach(model.examples, id: \.title) { ex in
                    let on = model.description == ex.text
                    Button {
                        withStageAnimation(Theme.Motion.quick) { model.description = ex.text }
                    } label: {
                        Text(ex.title)
                            .font(.ui(11, weight: .medium))
                            .foregroundStyle(on ? Color.tungsten : .textSecondary)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Capsule().strokeBorder(on ? Color.tungsten.opacity(0.6) : Color.hairlineStrong,
                                                               style: StrokeStyle(lineWidth: 1, dash: on ? [] : [2, 2])))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(ex.text)
                }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if let error = model.runner.error {
            ServiceErrorBanner(error: error, onDismiss: { model.runner.error = nil }, onRetry: model.run)
        } else if let m = model.manifest, model.shelf.hasScanned, !model.isDownloaded {
            Banner(.warning, title: "\(m.name) isn't downloaded yet",
                   message: "Get it in Models, or pick a voice designer that's on this Mac.") {
                Button("Get it in Models") { router.go(.models) }
                    .buttonStyle(.secondary).controlSize(.small)
            }
        }
    }
}

// MARK: - Auditions

private struct AuditionsColumn: View {
    @Bindable var model: DesignModel
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if model.auditions.isEmpty && !model.runner.isRunning {
                emptyBench
            } else {
                explainer
                header
                ForEach(rounds, id: \.self) { round in
                    roundSection(round)
                }
            }
        }
    }

    private var rounds: [Int] {
        var r = Array(Set(model.auditions.map(\.round)))
        if model.runner.isRunning, model.round > 0, !r.contains(model.round) { r.append(model.round) }
        return r.sorted(by: >)
    }

    private var emptyBench: some View {
        VStack(spacing: Theme.Space.l) {
            EmptyState(symbol: "wand.and.stars", title: "The auditions start here",
                       message: "Describe a voice, or start from an example, and press Audition (⌘↩).")
            explainer.frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.l)
    }

    private var explainer: some View {
        let cloners = model.cloningModels.map(\.name)
        let performers = cloners.isEmpty
            ? "To perform it you'll need a model that clones, such as Qwen3-TTS Base (download it in Models)."
            : "It's performed by a cloning model — on this Mac: \(ListFormatter.localizedString(byJoining: cloners))."
        return HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "person.2.wave.2").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.mint)
                .frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("Every audition is a different voice").textRole(.headline)
                Text("Not another take of the same one. The one you keep becomes a reusable voice in your library. \(performers)")
                    .textRole(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if cloners.isEmpty {
                Spacer(minLength: 0)
                Button("Open Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        }
        .padding(Theme.Space.m)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).fill(Color.mint.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Color.mint.opacity(0.18)))
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.s) {
            Text("Auditions").textRole(.heading)
            Text("\(model.auditions.count)").textRole(.mono, color: .textTertiary)
            Spacer(minLength: Theme.Space.s)
            if !model.unsaved.isEmpty {
                Button("Discard unkept", systemImage: "trash") { model.discardUnsaved() }
                    .buttonStyle(.ghost).controlSize(.small)
                    .disabled(model.runner.isBusy)
            }
            Button("More like this", systemImage: "sparkles") { model.moreLikeThis() }
                .buttonStyle(.secondary).controlSize(.small)
                .disabled(model.runner.isBusy || model.blockedReason != nil)
                .help("Audition \(model.count) more voices for the same brief")
        }
    }

    private func roundSection(_ round: Int) -> some View {
        let items = model.auditions.filter { $0.round == round }
        let pending = round == model.round ? model.pendingInRound : 0
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text("Round \(round)").textRole(.eyebrow)
                Rectangle().fill(Color.hairline).frame(height: 1)
            }
            ForEach(items) { a in AuditionCard(model: model, audition: a) }
            ForEach(0..<pending, id: \.self) { i in
                PendingAudition(number: items.count + i + 1, isNext: i == 0, stage: model.runner.stage)
            }
        }
    }
}

/// A candidate still being made.
private struct PendingAudition: View {
    let number: Int
    let isNext: Bool
    let stage: String?

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text("Nº \(number)").font(.display(19)).foregroundStyle(.textTertiary)
            if isNext { ActivityIndicator(size: 14) }
            Text(isNext ? (stage ?? "Waiting for the model…") : "In the wings")
                .textRole(.caption, color: isNext ? .textSecondary : .textTertiary)
            Spacer()
            Waveform(samples: Waveform.placeholder(count: 48, seed: number), progress: 0)
                .frame(width: 140, height: 22)
                .opacity(0.25)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 58)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                .strokeBorder(Color.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
    }
}

private struct AuditionCard: View {
    @Bindable var model: DesignModel
    let audition: DesignModel.Audition
    @Environment(VoiceLibrary.self) private var library

    private var isKeeping: Bool { model.keeping == audition.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WaveformPlayer(url: URL(fileURLWithPath: audition.candidate.audioPath),
                           title: audition.savedVoice?.name ?? "Audition Nº \(audition.number)",
                           subtitle: subtitle)
                .accessory { accessory }
                .overlay {
                    if audition.savedVoice != nil {
                        RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.mint.opacity(0.45), lineWidth: 1)
                    } else if isKeeping {
                        RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.tungsten.opacity(0.6), lineWidth: 1)
                    }
                }
            if isKeeping { keepForm.transition(.move(edge: .top).combined(with: .opacity)) }
            if let voice = audition.savedVoice {
                kept(voice).transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private var subtitle: String {
        var parts = [String(format: "%.1f s", audition.candidate.duration)]
        if let seed = audition.candidate.seed { parts.append("seed \(seed)") }
        parts.append(model.shelf.service.catalog.model(audition.candidate.modelID)?.name ?? audition.candidate.modelID)
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var accessory: some View {
        if audition.savedVoice != nil {
            StatusBadge("Kept", tone: .success)
        } else {
            Button("Keep", systemImage: "person.crop.circle.badge.plus") { withStageAnimation { model.beginKeeping(audition.id) } }
                .buttonStyle(.primary).controlSize(.small)
                .disabled(isKeeping)
            Button("Discard", systemImage: "xmark") { model.discard(audition.id) }
                .buttonStyle(.icon).controlSize(.small).help("Discard this audition")
        }
    }

    private var keepForm: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").textRole(.label, color: .textSecondary)
                    TextField(model.suggestedName, text: $model.keepName, prompt: Text(model.suggestedName).foregroundStyle(Color.textTertiary))
                        .textFieldStyle(.plain).font(.display(19)).foregroundStyle(.textPrimary)
                        .padding(.horizontal, 10).frame(height: 36)
                        .surface(.sunken, radius: Theme.Radius.s)
                        .onSubmit { Task { await model.keep() } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Tags").textRole(.label, color: .textSecondary)
                TagEditor(tags: $model.keepTags, suggestions: library.allTags)
            }
            if let e = model.saveError { Banner(.danger, title: "The voice wasn't saved", message: e) }
            HStack(spacing: Theme.Space.s) {
                Button(model.isSaving ? "Saving…" : "Save to library", systemImage: "checkmark") { Task { await model.keep() } }
                    .buttonStyle(.primary)
                    .disabled(model.isSaving)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Cancel") { withStageAnimation { model.keeping = nil } }.buttonStyle(.ghost)
                Spacer(minLength: 0)
                Text("Its line becomes the reference transcript.").textRole(.caption, color: .textTertiary).lineLimit(1)
            }
        }
        .padding(Theme.Space.l)
        .padding(.top, Theme.Space.xs)
        .background(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.l, bottomTrailingRadius: Theme.Radius.l, style: .continuous)
                .fill(Color.surfaceSunken.opacity(0.7))
                .padding(.horizontal, Theme.Space.m)
        }
    }

    private func kept(_ voice: Voice) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Color.mint)
                Text("“\(voice.name)” joined your company.").textRole(.label, color: .mint)
            }
            if model.tryoutFor == audition.id {
                VoiceTryoutPanel(tryout: model.tryout)
            }
        }
        .padding(Theme.Space.l)
        .background(alignment: .top) {
            UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.l, bottomTrailingRadius: Theme.Radius.l, style: .continuous)
                .fill(Color.mint.opacity(0.04))
                .overlay(UnevenRoundedRectangle(bottomLeadingRadius: Theme.Radius.l, bottomTrailingRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(Color.mint.opacity(0.15)))
                .padding(.horizontal, Theme.Space.m)
        }
    }
}

// MARK: - First run

private struct DesignFirstRun: View {
    let model: DesignModel
    @Environment(Router.self) private var router

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            EmptyState(symbol: "wand.and.stars", title: "No voice designer on this Mac",
                       message: "Designing a voice from a description needs a model that can do it. Qwen3-TTS VoiceDesign is the one to start with; VoxCPM2 can too, and OmniVoice builds one from attributes like gender, age and accent.") {
                Button("Open Models", systemImage: "arrow.down.circle") { router.go(.models) }
                    .buttonStyle(.primary).controlSize(.large)
            }
            HStack(alignment: .top, spacing: Theme.Space.m) {
                ForEach(model.designModels.sorted { ($0.id == "qwen3-tts-voicedesign" ? 0 : 1) < ($1.id == "qwen3-tts-voicedesign" ? 0 : 1) }.prefix(3)) { m in
                    Button { router.go(.models) } label: {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(m.name).textRole(.heading)
                            Text(m.summary).textRole(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            PerforatedDivider().padding(.vertical, -4)
                            HStack {
                                Text(MemoryGauge.bytes(m.defaultVariant.downloadBytes)).textRole(.mono, color: .textSecondary)
                                Spacer()
                                Text(m.license.name).textRole(.monoSmall, color: m.license.commercialUse == false ? .footlight : .textTertiary)
                            }
                        }
                        .padding(Theme.Space.l)
                        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                        .surface(.card)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 820)
        }
        .frame(maxWidth: .infinity)
    }
}
