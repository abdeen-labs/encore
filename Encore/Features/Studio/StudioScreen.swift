import EncoreCore
import SwiftUI

/// Text to speech. Write the lines, cast a voice, perform, collect takes.
///
/// Layout follows the room it gets: a writing desk (cast, script, perform) is always center stage; the wings
/// (tuning and takes) sit beside it as two columns when there's space, one tabbed column when there's less,
/// and a drawer over the desk at the smallest window sizes.
struct StudioScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Studio") { StudioModel(deps: deps) }
        StudioStage(model: model)
    }
}

struct StudioStage: View {
    @Bindable var model: StudioModel
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @Environment(PronunciationStore.self) private var pronunciationStore

    @State private var layout: Layout = .medium
    @State private var drawerOpen = false

    nonisolated enum Layout: Sendable, Equatable { case narrow, medium, wide }

    var body: some View {
        ScreenScaffold(.studio, scrolls: false) {
            content
        } actions: {
            headerActions
        }
        .task { await model.prepare() }
        .pronunciationSheet(isPresented: $model.showPronunciations)
        #if DEBUG
        .modifier(StudioFixtureChrome())
        #endif
        .onChange(of: model.sessionTakeIDs) { _, _ in if layout == .narrow { withStageAnimation { drawerOpen = true } } }
    }

    // MARK: Header

    @ViewBuilder private var headerActions: some View {
        if !model.needsFirstModel {
            if layout == .narrow {
                Button {
                    withStageAnimation { if drawerOpen && model.wingsTab == .tuning { drawerOpen = false } else { model.wingsTab = .tuning; drawerOpen = true } }
                } label: { Label("Tuning", systemImage: "slider.horizontal.3") }
                    .buttonStyle(.ghost)
                Button {
                    withStageAnimation { if drawerOpen && model.wingsTab == .takes { drawerOpen = false } else { model.wingsTab = .takes; drawerOpen = true } }
                } label: {
                    HStack(spacing: 6) {
                        Label("Takes", systemImage: "square.stack")
                        if model.takesTotal > 0 { CountBadge(model.takesTotal) }
                    }
                }
                    .buttonStyle(.ghost)
            }
            Button {
                model.showPronunciations = true
            } label: {
                if layout == .narrow {
                    Image(systemName: "character.book.closed")
                } else {
                    Label(pronunciationStore.entries.isEmpty ? "Pronunciations" : "Pronunciations · \(pronunciationStore.entries.filter(\.enabled).count)",
                          systemImage: "character.book.closed")
                }
            }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .help("Pronunciations: words the voice should say differently")
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !model.shelf.hasScanned {
            Color.clear
        } else if model.needsFirstModel {
            VStack(spacing: 0) {
                FirstModelStage(symbol: "theatermasks", title: "Well, hello there",
                                message: "Encore talks with models that run right here on your Mac. Grab one to get going: Soprano is tiny and quick, the others can clone a voice.",
                                starterIDs: ["soprano", "qwen3-tts-base", "chatterbox-turbo"])
                if model.takesTotal > 0 {
                    Button("Earlier takes in History") { router.go(.history) }
                        .buttonStyle(.ghost)
                        .controlSize(.small)
                        .padding(.bottom, Theme.Space.m)
                }
            }
        } else {
            // Measure the space offered (not the content), so a wide layout can't hold itself open.
            GeometryReader { geo in
                let fit: Layout = geo.size.width >= 1100 ? .wide : (geo.size.width >= 760 ? .medium : .narrow)
                stage(fit)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    .onAppear { layout = fit }
                    .onChange(of: fit) { _, f in layout = f }
            }
        }
    }

    @ViewBuilder private func stage(_ layout: Layout) -> some View {
        switch layout {
        case .wide:
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                TuningPanel(model: model).frame(width: 268)
                    .padding(.trailing, Theme.Space.l)
                    .overlay(alignment: .trailing) { wingEdge }
                DeskView(model: model).zIndex(1)
                TakesPanel(model: model).frame(width: 330)
                    .padding(.leading, Theme.Space.l)
                    .overlay(alignment: .leading) { wingEdge }
            }
        case .medium:
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                DeskView(model: model).zIndex(1)
                Wings(model: model).frame(width: 312)
                    .padding(.leading, Theme.Space.l)
                    .overlay(alignment: .leading) { wingEdge }
            }
        case .narrow:
            DeskView(model: model)
                .overlay(alignment: .trailing) {
                    if drawerOpen {
                        Wings(model: model, onClose: { withStageAnimation { drawerOpen = false } })
                            .frame(width: 320)
                            .padding(Theme.Space.m)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Color.surface)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                            }
                            .elevation()
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
        }
    }

    /// The rule between desk and wings.
    private var wingEdge: some View { Hairline(.vertical) }
}

// MARK: - Desk

/// Cast, direction, the script, and the perform bar.
private struct DeskView: View {
    @Bindable var model: StudioModel
    @Environment(Router.self) private var router

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let manifest = model.manifest {
                castingBar(manifest)
                    .zIndex(2)
                if let kind = model.directionKind, !directionIgnored(kind) { direction(kind, manifest: manifest) }
                EditorWell(model: model, manifest: manifest)
                    .frame(maxHeight: .infinity)
                notices(manifest)
            } else {
                Spacer()
            }
            RunSurface(runner: model.runner, title: "Perform", systemImage: "play.fill",
                       blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                       action: model.perform)
                .padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .stageAnimation(Theme.Motion.standard, value: model.runner.error == nil)
    }

    private func castingBar(_ manifest: ModelManifest) -> some View {
        HStack(spacing: Theme.Space.s) {
            ModelPicker(task: .tts, feature: .speech, selection: $model.choice)
                .frame(minWidth: 120, maxWidth: .infinity)
                .layoutPriority(1)
            VoicePicker(manifest: manifest, selection: $model.voice, language: model.language)
                .frame(minWidth: 120, maxWidth: .infinity)
                .layoutPriority(1)
            if manifest.languages.count > 1 {
                LanguagePicker(manifest: manifest, selection: $model.language)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    /// A voice description does nothing while a library voice is cast, so the field steps aside.
    private func directionIgnored(_ kind: StudioModel.DirectionKind) -> Bool {
        if case .library = model.voice, kind == .description { return true }
        return false
    }

    private func direction(_ kind: StudioModel.DirectionKind, manifest: ModelManifest) -> some View {
        StageTextField(kind == .style ? "Direction, e.g. calm and warm, with a hint of a smile"
                                      : "Describe the voice, e.g. a raspy older man, slow and deliberate",
                       text: $model.instruct, symbol: kind == .style ? "theatermasks" : "wand.and.stars")
            .help(kind == .style ? "How to say it. Sent to \(manifest.name) as a style instruction."
                  : "With the voice on Automatic, \(manifest.name) designs a voice from this description.")
    }

    @ViewBuilder private func notices(_ manifest: ModelManifest) -> some View {
        if let error = model.runner.error {
            ServiceErrorBanner(error: error, onDismiss: { withStageAnimation { model.runner.error = nil } },
                               onRetry: model.perform)
        } else if model.draftModelRetired {
            Banner(.neutral, title: "The model this draft used is no longer in Encore",
                   message: "Your script is kept. Its voice and settings went with that model, so it's set to \(manifest.name) now.",
                   onDismiss: { withStageAnimation { model.draftModelRetired = false } })
        } else if model.shelf.hasScanned, !model.isDownloaded {
            Banner(.warning, title: "\(manifest.name) isn't downloaded yet",
                   message: downloadMessage(manifest)) {
                Button("Get it in Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        } else if let pick = model.shelf.missedBestRuntime(for: manifest) {
            BestRuntimeNote(manifest: manifest, pick: pick) { router.go(.settings) }
        }
    }

    /// What to download, in plain words ("the Balanced version (1.2 GB)") when the model comes in several.
    private func downloadMessage(_ manifest: ModelManifest) -> String {
        let variant = manifest.variant(model.choice?.variantID)
        let size = Bytes.file(variant.downloadBytes)
        let what = manifest.variants.count > 1 ? "the \(variant.friendlyName(in: manifest)) version (\(size))" : "it (\(size))"
        return "Download \(what) in Models, or pick a model that's on this Mac."
    }
}

// MARK: - Editor

/// The script well: highlighted editor, tag chips, and the stats/issues footer.
private struct EditorWell: View {
    @Bindable var model: StudioModel
    let manifest: ModelManifest
    @State private var issueCursor = 0

    var body: some View {
        let plan = model.plan
        VStack(spacing: 0) {
            TaggedScriptEditor(text: $model.script, parsed: plan?.parsed, controller: model.editor,
                               placeholder: "Write the lines to perform…",
                               onCommandReturn: model.perform, onCommandPeriod: model.cancel)
                // At the smallest window the script gets about 260 pt; this floor holds even with a banner showing.
                .frame(minHeight: 160)
            Hairline()
            TagInserter(manifest: manifest) { model.editor.insert($0) }
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, 7)
            Hairline()
            footer(plan)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
        }
        .surface(.sunken, radius: Theme.Radius.l)
    }

    private func footer(_ plan: ScriptPlan?) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(count).textRole(.caption, color: .textTertiary).monospacedDigit().lineLimit(1)
                .fixedSize()
                .help(details(plan) ?? "")
            Spacer(minLength: Theme.Space.s)
            issues(plan)
        }
    }

    /// "244 characters".
    private var count: String {
        let chars = model.script.count
        return chars == 1 ? "1 character" : "\(chars.formatted()) characters"
    }

    /// How the script will be performed (parts, tags, pauses, voices), for the count's tooltip.
    private func details(_ plan: ScriptPlan?) -> String? {
        guard let plan, !model.script.isEmpty else { return nil }
        var parts: [String] = []
        let chunks = plan.chunks.count
        parts.append(chunks == 1 ? "1 chunk" : "\(chunks) chunks")
        let tags = plan.parsed.tags.count
        if tags > 0 { parts.append(tags == 1 ? "1 tag" : "\(tags) tags") }
        let pauses = plan.items.reduce(0.0) { if case .pause(let s, _) = $1 { $0 + s } else { $0 } }
        if pauses > 0 { parts.append(String(format: "%.1f s of pauses", pauses)) }
        let voices = Set(plan.chunks.compactMap(\.voice)).count
        if voices > 0 { parts.append("\(voices + 1) voices") }
        return parts.joined(separator: " · ")
    }

    /// The most important issue, clickable to jump to it (repeated clicks walk through the rest).
    @ViewBuilder private func issues(_ plan: ScriptPlan?) -> some View {
        let all = (plan?.issues ?? []).sorted { rank($0.severity) > rank($1.severity) }
        if let first = all.first {
            let shown = all[min(issueCursor, all.count - 1)]
            Button {
                model.editor.select(shown.utf16Range)
                issueCursor = (issueCursor + 1) % all.count
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: first.severity == .error ? "xmark.octagon.fill" : (first.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(first.severity))
                    Text(shown.message).textRole(.caption).lineLimit(1).truncationMode(.tail)
                    if all.count > 1 { Text("\(all.count)").textRole(.monoSmall, color: .textTertiary).fixedSize() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)
            .help(all.map(\.message).joined(separator: "\n"))
            .onChange(of: all.count) { _, _ in issueCursor = 0 }
        }
    }

    private func rank(_ s: ScriptIssue.Severity) -> Int { s == .error ? 2 : (s == .warning ? 1 : 0) }
    private func color(_ s: ScriptIssue.Severity) -> Color { s == .error ? .cherryInk : (s == .warning ? .honeyInk : .textTertiary) }
}

// MARK: - Wings

/// Tuning and takes in one column, switched by tabs.
private struct Wings: View {
    @Bindable var model: StudioModel
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                SegmentedControl(selection: $model.wingsTab, options: StudioModel.WingsTab.allCases,
                                 count: { $0 == .takes && model.takesTotal > 0 ? model.takesTotal : nil }) { $0.rawValue }
                .controlSize(.small)
                Spacer()
                if let onClose {
                    Button("Close", systemImage: "xmark", action: onClose).buttonStyle(.icon).controlSize(.small)
                }
            }
            switch model.wingsTab {
            case .tuning: TuningPanel(model: model, showsTitle: false)
            case .takes: TakesPanel(model: model, showsTitle: false)
            }
        }
    }
}

/// Parameters, presets and post-processing for the chosen model.
private struct TuningPanel: View {
    @Bindable var model: StudioModel
    var showsTitle = true

    var body: some View {
        if let manifest = model.manifest {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    // With tabs showing, the tab already says "Tuning": the row is just the presets menu.
                    HStack(alignment: .center) {
                        if showsTitle { Text("Tuning").textRole(.section) }
                        Spacer()
                        PresetsMenu(manifest: manifest, parameters: $model.parameters, post: $model.post)
                    }
                    ParameterPanel(manifest: manifest, values: $model.parameters, advancedExpanded: $model.showAdvanced)
                    Hairline().padding(.vertical, Theme.Space.xxs)
                    Text("Finishing").textRole(.section)
                    PostProcessingControls(options: $model.post)
                    Toggle(isOn: $model.autoChunk) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Split long text").textRole(.body)
                            Text("At sentence ends, up to \(manifest.maxChunkCharacters) characters").textRole(.caption, color: .textTertiary)
                        }
                    }
                    .toggleStyle(.stage)
                }
                .padding(.leading, Theme.Space.s)
                .padding(.trailing, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)
            }
            .scrollIndicators(.automatic)
        }
    }
}

/// This session's and recent takes, newest first.
private struct TakesPanel: View {
    @Bindable var model: StudioModel
    var showsTitle = true
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if showsTitle {
                HStack(spacing: Theme.Space.s) {
                    Text("Takes").textRole(.section)
                    if model.takesTotal > 0 { CountBadge(model.takesTotal) }
                    Spacer()
                }
            }
            if model.takes.isEmpty {
                EmptyState(symbol: "waveform", title: "No takes yet",
                           message: "Each performance pops up here, newest first, and stays in History.", style: .plain)
                Spacer(minLength: 0)
            } else {
                // The newest take of this session opens up to show its waveform.
                let newest = model.takes.first { model.sessionTakeIDs.contains($0.id) }?.id
                let first = model.takes.first?.id
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.takes) { item in
                            if let record = item.generation {
                                VStack(spacing: 0) {
                                    if item.id != first { Hairline() }
                                    TakeRow(item: item, record: record, isNewest: item.id == newest,
                                            onFavorite: { model.toggleFavorite(item) },
                                            onReuse: {
                                                if let problem = model.reuse(record) { toasts.show(problem, tone: .warning) }
                                                else { toasts.show("Loaded the take's settings", symbol: "arrow.uturn.backward") }
                                            },
                                            onCopy: { model.copyScript(record); toasts.show("Script copied", symbol: "doc.on.doc") },
                                            onDelete: { model.delete(item) })
                                }
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                            }
                        }
                        if model.takesTotal > model.takes.count {
                            Button("All \(model.takesTotal) takes in History", systemImage: "arrow.right") { router.go(.history) }
                                .buttonStyle(.ghost).controlSize(.small)
                                .padding(.top, Theme.Space.s)
                        }
                    }
                    .padding(.trailing, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.l)
                }
                .scrollIndicators(.automatic)
            }
        }
    }
}

#if DEBUG
/// Snapshot fixtures: pickers and the pronunciation sheet drawn in place so they appear in the image.
private struct StudioFixtureChrome: ViewModifier {
    func body(content: Content) -> some View {
        let state = StudioFixtures.state
        content
            .environment(\.inlinePickerPanels, StudioFixtures.isRequested)
            .environment(\.snapshotOpenPicker, state == "modelPicker" ? "model" : (state == "voicePicker" ? "voice" : nil))
            .overlay {
                if state == "pronunciations" {
                    ZStack {
                        Color.shadow.opacity(0.22)
                        PronunciationEditor()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                            .elevation()
                    }
                }
            }
    }
}
#endif
