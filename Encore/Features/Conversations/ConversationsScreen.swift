import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Multi-speaker scripts, cast and staged.
///
/// The script is a running order of lines, each in its speaker's color, with the pause after it shown (and
/// adjustable) between lines. The cast and the staging (model, language, pauses, tuning) sit in the wings beside
/// it, or in a drawer when the window is narrow. Lines already rendered are marked and reused, so after an edit
/// only the changed lines are generated again; any line can be auditioned on its own.
struct ConversationsScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Conversations") { ConversationsModel(deps: deps) }
        ConversationsStage(model: model)
    }
}

struct ConversationsStage: View {
    @Bindable var model: ConversationsModel
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts
    @State private var width: CGFloat = 900
    @State private var height: CGFloat = 600
    @State private var drawerOpen = false
    @State private var importing = false
    @State private var confirmNew = false
    @State private var showPronunciations = false

    private var wide: Bool { width >= 860 }

    var body: some View {
        ScreenScaffold(.conversations, scrolls: false) {
            content
        } actions: {
            headerActions
        }
        .task { await model.prepare() }
        .pronunciationSheet(isPresented: $showPronunciations)
        .fileImporter(isPresented: $importing, allowedContentTypes: ConversationsModel.scriptTypes) { result in
            if case .success(let url) = result { importScript(url) }
        }
        .confirmationDialog("Start a new script?", isPresented: $confirmNew) {
            Button("New script", role: .destructive) { withStageAnimation { model.newScript() } }
        } message: {
            Text("The current script and its cast are replaced. Export it first if you want to keep it.")
        }
        #if DEBUG
        .environment(\.inlinePickerPanels, ConversationsFixtures.isRequested)
        #endif
    }

    private func importScript(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try withStageAnimation { try model.importScript(from: url) }
        } catch {
            toasts.show(error.localizedDescription, tone: .warning, duration: 5)
        }
    }

    @ViewBuilder private var headerActions: some View {
        if !model.needsFirstModel {
            if !wide {
                Button {
                    withStageAnimation { drawerOpen.toggle() }
                } label: { Label("Cast & staging", systemImage: "person.2.badge.gearshape") }
                    .buttonStyle(.ghost)
            }
            Button("Pronunciations", systemImage: "character.book.closed") { showPronunciations = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.secondary).controlSize(.small)
                .help("Pronunciations: words the voices should say differently")
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                .buttonStyle(.secondary).controlSize(.small)
                .help("Import a .txt or .pdf script")
            Menu {
                Button("Export script as text…") {
                    model.exportScript { r in
                        if case .success(let name) = r { toasts.show("Saved “\(name)”", tone: .success) }
                        if case .failure(let e) = r { toasts.show(e.localizedDescription, tone: .danger) }
                    }
                }
                .disabled(model.lines.isEmpty)
                Button("Copy script") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.exportText, forType: .string)
                    toasts.show("Script copied", symbol: "doc.on.doc")
                }
                .disabled(model.lines.isEmpty)
                Divider()
                Button("New script…") { confirmNew = true }.disabled(model.lines.isEmpty)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(.textSecondary)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Export, copy, or start over")
        }
    }

    @ViewBuilder private var content: some View {
        if !model.shelf.hasScanned {
            Color.clear
        } else if model.needsFirstModel {
            ConversationsFirstRun()
        } else {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                if wide {
                    StagingColumn(model: model)
                        .frame(width: 286)
                        .padding(.trailing, Theme.Space.l)
                        .overlay(alignment: .trailing) { wingEdge }
                }
                ScriptColumn(model: model, compact: !wide, shortWindow: height < 520,
                             openCast: { withStageAnimation { drawerOpen = true } }, importScript: importScript, chooseFile: { importing = true })
                    .zIndex(1)
            }
            .overlay(alignment: .trailing) {
                if drawerOpen && !wide {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        HStack {
                            Text("Cast & staging").textRole(.heading)
                            Spacer()
                            Button("Close", systemImage: "xmark") { withStageAnimation { drawerOpen = false } }
                                .buttonStyle(.icon).controlSize(.small)
                        }
                        StagingColumn(model: model)
                    }
                    .frame(width: 320)
                    .padding(Theme.Space.m)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Color.surface)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                    }
                    .elevation()
                    .padding(.bottom, Theme.Space.m)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(3)
                }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { width = $0.width; height = $0.height }
        }
    }

    private var wingEdge: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, Color.hairlineStrong, Color.tungsten.opacity(0.18), Color.hairlineStrong, .clear],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 1)
    }
}

// MARK: - Script column

private struct ScriptColumn: View {
    @Bindable var model: ConversationsModel
    let compact: Bool
    let shortWindow: Bool
    let openCast: () -> Void
    let importScript: (URL) -> Void
    let chooseFile: () -> Void
    @Environment(Router.self) private var router
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            titleRow
            if let report = model.importReport { ScriptImportBanner(model: model, report: report) }
            if compact, !model.speakers.isEmpty { CastStrip(model: model, open: openCast) }
            if model.lines.isEmpty {
                EmptyScript(model: model, chooseFile: chooseFile)
                    .frame(maxHeight: .infinity)
            } else {
                LinesList(model: model)
                    .frame(maxHeight: .infinity)
            }
            notices
            if let result = model.result {
                ResultCard(model: model, result: result, compact: shortWindow)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            RunSurface(runner: model.runner, title: model.result == nil ? "Stage it" : "Render again", systemImage: "play.fill",
                       blockedReason: model.runner.error == nil ? model.blockedReason : nil,
                       idleNote: model.idleNote, action: model.render)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
                    .strokeBorder(Color.tungsten, style: StrokeStyle(lineWidth: 1.5, dash: [0.1, 7]))
                    .background(Color.tungsten.opacity(0.05))
                    .overlay(Text("Drop to import the script").textRole(.headline, color: .tungsten))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: Self.isScript) else { return false }
            importScript(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .stageAnimation(Theme.Motion.standard, value: model.runner.error == nil)
    }

    nonisolated static func isScript(_ url: URL) -> Bool { ["txt", "text", "pdf", "md", "markdown", "fountain"].contains(url.pathExtension.lowercased()) }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            TextField("Untitled conversation", text: $model.script.title)
                .textFieldStyle(.plain)
                .font(.display(22))
                .foregroundStyle(.textPrimary)
                .frame(minWidth: 120)
            if !model.lines.isEmpty {
                Text(stats).textRole(.monoSmall, color: .textTertiary).lineLimit(1).fixedSize()
            }
        }
    }

    private var stats: String {
        let n = model.lines.count
        return "\(n) line\(n == 1 ? "" : "s") · \(model.speakingCount) speaking · ≈ \(Timecode.string(model.estimatedSeconds, tenths: false))"
    }

    @ViewBuilder private var notices: some View {
        if let error = model.runner.error {
            ServiceErrorBanner(error: error, onDismiss: { withStageAnimation { model.runner.error = nil } }, onRetry: model.render)
        } else if let error = model.auditionRunner.error {
            ServiceErrorBanner(error: error, onDismiss: { withStageAnimation { model.auditionRunner.error = nil } })
        } else if let m = model.manifest, model.shelf.hasScanned, !model.isDownloaded {
            Banner(.warning, title: "\(m.name) isn't downloaded yet",
                   message: "Get it in Models, or choose a model that's on this Mac.") {
                Button("Get it in Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
            }
        } else if let c = model.cloningProblem, let m = model.manifest {
            Banner(.warning, title: "\(m.name) can't speak in library voices",
                   message: "\(ListFormatter.localizedString(byJoining: c.names)) \(c.names.count == 1 ? "is" : "are") cast with a voice from your library, which needs a model that clones. "
                    + (c.suggestion.map { "\($0.name) can." } ?? "Download one in Models, or cast them with \(m.name)'s own voices.")) {
                if let s = c.suggestion {
                    Button("Use \(s.name)") { withStageAnimation { model.switchToCloningModel() } }.buttonStyle(.secondary).controlSize(.small)
                } else {
                    Button("Open Models") { router.go(.models) }.buttonStyle(.secondary).controlSize(.small)
                }
            }
        }
    }
}

/// What an import found: the layout it recognized, the cast, and anything worth checking.
private struct ScriptImportBanner: View {
    let model: ConversationsModel
    let report: ConversationsModel.ImportReport

    var body: some View {
        let layout: String = switch report.layout {
        case .labeled: "labeled lines (Name: text)"
        case .screenplay: "a screenplay"
        case .paragraphs: "paragraphs without names"
        }
        var message = "Read as \(layout): \(report.speakers) speaker\(report.speakers == 1 ? "" : "s"), \(report.lines) lines."
        if !report.castFromLibrary.isEmpty { message += " Cast from your library: \(report.castFromLibrary.joined(separator: ", "))." }
        if !report.notes.isEmpty { message += " " + report.notes.joined(separator: " ") }
        return Banner(report.layout == .paragraphs ? .warning : .neutral, title: "Imported “\(report.fileName)”", message: message,
                      onDismiss: { withStageAnimation { model.dismissImportReport() } }) {
            if model.canUndoImport {
                Button("Undo import") { withStageAnimation { model.undoImport() } }.buttonStyle(.ghost).controlSize(.small)
            }
        }
    }
}

private struct EmptyScript: View {
    let model: ConversationsModel
    let chooseFile: () -> Void

    var body: some View {
        // Scrolls rather than pushing the page taller than a small window.
        ScrollView {
            VStack(spacing: Theme.Space.m) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.tungsten)
                    .glow(.tungsten, radius: 14, intensity: 0.45)
                Text("Write a scene").font(.display(26)).foregroundStyle(.textPrimary)
                Text("Import a .txt or .pdf script (labeled lines or a screenplay), drop one here, or start writing.")
                    .textRole(.body, color: .textSecondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                HStack(spacing: Theme.Space.s) {
                    Button("Import a script…", systemImage: "square.and.arrow.down", action: chooseFile)
                        .buttonStyle(.primary)
                    Button("Start writing", systemImage: "pencil") { withStageAnimation { model.startWriting() } }
                        .buttonStyle(.secondary)
                }
                .padding(.top, Theme.Space.xs)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .surface(.sunken)
    }
}

// MARK: - Lines

private struct LinesList: View {
    @Bindable var model: ConversationsModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.lines.enumerated()), id: \.element.id) { i, line in
                        LineRow(model: model, line: line, number: i + 1)
                            .id(line.id)
                        if i + 1 < model.lines.count {
                            PauseGap(model: model, line: line)
                        }
                    }
                    Button {
                        withStageAnimation { model.editingLineID = model.addLine(after: model.lines.last?.id) }
                    } label: {
                        Label("Add a line", systemImage: "plus")
                            .font(.ui(12.5, weight: .medium))
                            .foregroundStyle(.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.Space.l)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .padding(.top, Theme.Space.xs)
                }
                .padding(.vertical, Theme.Space.s)
            }
            .scrollIndicators(.automatic)
            .surface(.sunken)
            .onChange(of: model.renderingIndex) { _, i in
                guard let i, i < model.spokenLines.count else { return }
                withStageAnimation { proxy.scrollTo(model.spokenLines[i].id, anchor: .center) }
            }
            .onChange(of: model.editingLineID) { _, id in
                if let id { withStageAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            .onAppear { if let id = model.editingLineID { proxy.scrollTo(id, anchor: .center) } }
        }
    }
}

/// One line of the script: number, speaker (in their color), the text with its tags lit, and its state.
private struct LineRow: View {
    @Bindable var model: ConversationsModel
    let line: ConversationScript.Line
    let number: Int
    @State private var hovered = false
    @State private var dropTarget = false

    private var isEditing: Bool { model.editingLineID == line.id }

    var body: some View {
        let speaker = model.speaker(line.speakerID)
        let tint = model.tint(line.speakerID)
        let state = model.state(of: line)
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Text("\(number)")
                .font(.mono(10.5, weight: .medium))
                .foregroundStyle(state == .rendering ? Color.tungsten : .textTertiary)
                .frame(width: 22, alignment: .trailing)
                .padding(.top, 3)
                .draggable(line.id.uuidString) {
                    Text(speaker?.name ?? "Line").textRole(.headline, color: tint)
                        .padding(8).background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 6))
                }
                .help("Drag to reorder")
            Capsule().fill(tint.opacity(state == .empty ? 0.3 : 0.9)).frame(width: 2.5)
                .glow(tint, radius: 4, intensity: state == .rendering ? 0.7 : 0)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Theme.Space.s) {
                    speakerMenu(speaker, tint: tint)
                    Spacer(minLength: Theme.Space.s)
                    if hovered || isEditing || state == .rendering { actions(state) }
                    StateMark(state: state, reuse: model.reuseLines)
                }
                if isEditing {
                    LineEditor(model: model, line: line, speakerName: speaker?.name ?? "this speaker")
                } else {
                    Text(attributedText)
                        .font(.ui(14.5))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentShape(Rectangle())
                        .onTapGesture { withStageAnimation(Theme.Motion.quick) { model.endEditing(); model.editingLineID = line.id } }
                        .help("Click to edit")
                }
            }
        }
        .padding(.leading, Theme.Space.s)
        .padding(.trailing, Theme.Space.m)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
            if isEditing {
                shape.fill(tint.opacity(0.06)).overlay(shape.strokeBorder(tint.opacity(0.35), lineWidth: 1))
            } else if state == .rendering {
                shape.fill(Color.tungsten.opacity(0.06))
            } else if hovered {
                shape.fill(Color.textPrimary.opacity(0.03))
            }
        }
        .overlay(alignment: .top) {
            if dropTarget { Capsule().fill(Color.tungsten).frame(height: 2).glow(.tungsten, radius: 4, intensity: 0.6).offset(y: -1) }
        }
        .padding(.horizontal, Theme.Space.s)
        .onHover { hovered = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s), id != line.id else { return false }
            withStageAnimation { model.moveLine(id, before: line.id) }
            return true
        } isTargeted: { dropTarget = $0 }
        .contextMenu { menuItems }
    }

    private func speakerMenu(_ speaker: ConversationScript.Speaker?, tint: Color) -> some View {
        Menu {
            ForEach(model.speakers) { s in
                Button {
                    model.setSpeaker(s.id, for: line.id)
                } label: {
                    if s.id == line.speakerID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                }
            }
            Divider()
            Button("New speaker…") {
                let id = model.addSpeaker()
                model.setSpeaker(id, for: line.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text((speaker?.name ?? "Nobody").uppercased())
                    .font(.ui(10.5, weight: .bold)).tracking(1.1)
                    .foregroundStyle(tint)
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold)).foregroundStyle(tint.opacity(hovered ? 0.8 : 0))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Who says this line")
    }

    @ViewBuilder private func actions(_ state: ConversationsModel.LineState) -> some View {
        HStack(spacing: 2) {
            if model.auditioningLineID == line.id {
                Button("Stop", systemImage: "stop.fill") { model.auditionRunner.cancel() }
                    .buttonStyle(.icon).controlSize(.small).help("Stop the audition")
            } else if model.auditionedLineID == line.id, model.auditionPlayer.isLoaded {
                Button(model.auditionPlayer.isPlaying ? "Pause" : "Play again", systemImage: model.auditionPlayer.isPlaying ? "pause.fill" : "play.fill") {
                    model.auditionPlayer.toggle()
                }
                .buttonStyle(.icon(tone: .accent)).controlSize(.small).help("Play the audition again")
                Button("Audition again", systemImage: "arrow.clockwise") { model.audition(line.id) }
                    .buttonStyle(.icon).controlSize(.small).help("Audition this line again")
                    .disabled(model.auditionRunner.isBusy || state == .empty)
            } else {
                Button("Audition", systemImage: "play.circle") { model.audition(line.id) }
                    .buttonStyle(.icon(tone: .accent)).controlSize(.small)
                    .help("Hear this line on its own (not saved to History)")
                    .disabled(model.auditionRunner.isBusy || state == .empty || model.manifest == nil)
            }
            Menu { menuItems } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    @ViewBuilder private var menuItems: some View {
        Button(isEditing ? "Done editing" : "Edit") {
            if isEditing { model.endEditing() } else { model.endEditing(); model.editingLineID = line.id }
        }
        Button("Audition") { model.audition(line.id) }.disabled(model.auditionRunner.isBusy)
        Divider()
        Button("Insert a line after") { withStageAnimation { model.editingLineID = model.addLine(after: line.id) } }
        Button(line.text.contains(where: \.isNewline) ? "Split at the line breaks" : "Split into sentences") {
            withStageAnimation { model.splitLine(line.id) }
        }
        .disabled(!model.canSplit(line))
        Button("Merge with the next line") { withStageAnimation { model.mergeWithNext(line.id) } }.disabled(!model.canMerge(line.id))
        Divider()
        Button("Move up") { withStageAnimation { model.moveLine(line.id, by: -1) } }.disabled(number == 1)
        Button("Move down") { withStageAnimation { model.moveLine(line.id, by: 1) } }.disabled(number == model.lines.count)
        Divider()
        Button("Delete line", role: .destructive) { withStageAnimation { model.deleteLine(line.id) } }
    }

    /// The text with its tags colored as in the editor.
    private var attributedText: AttributedString {
        let text = line.text
        guard !text.isEmpty else {
            var a = AttributedString("Empty line: click to write it")
            a.foregroundColor = .textTertiary
            a.font = .display(15, italic: true)
            return a
        }
        var a = AttributedString(text)
        a.foregroundColor = .textPrimary
        for tag in model.parser.parse(text).tags {
            guard let r = Range<AttributedString.Index>(tag.range, in: a) else { continue }
            a[r].foregroundColor = ScriptTagStyle.color(tag.kind)
            a[r].font = .mono(12.5, weight: .medium)
            a[r].backgroundColor = ScriptTagStyle.color(tag.kind).opacity(0.11)
        }
        return a
    }
}

/// Ready / to generate / generating / done, as a small mark at the end of a line's header.
private struct StateMark: View {
    let state: ConversationsModel.LineState
    let reuse: Bool

    var body: some View {
        Group {
            switch state {
            case .empty: EmptyView()
            case .pending:
                Circle().strokeBorder(Color.tungsten.opacity(0.75), style: StrokeStyle(lineWidth: 1.3, dash: [2, 2]))
                    .frame(width: 11, height: 11)
                    .help(reuse ? "New or changed: will be generated" : "Will be generated (reuse is off)")
            case .ready:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11.5)).foregroundStyle(Color.mint.opacity(0.85))
                    .help("Rendered already: reused as is, so it costs nothing to render again")
            case .rendering:
                ActivityIndicator(tone: .accent, size: 11)
            case .done:
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.mint)
            }
        }
        .frame(width: 14, height: 14)
    }
}

/// The editor for the line being edited: tags lit as you type, chips to insert tags, Return to split.
private struct LineEditor: View {
    @Bindable var model: ConversationsModel
    let line: ConversationScript.Line
    let speakerName: String

    var body: some View {
        let text = Binding(get: { model.lines.first { $0.id == line.id }?.text ?? "" },
                           set: { model.setText($0, for: line.id) })
        VStack(alignment: .leading, spacing: 0) {
            TaggedScriptEditor(text: text, parsed: model.parser.parse(text.wrappedValue), controller: model.editor,
                               placeholder: "What does \(speakerName) say?", fontSize: 14.5,
                               onCommandReturn: { withStageAnimation(Theme.Motion.quick) { model.endEditing() } })
                .frame(height: height(for: text.wrappedValue))
            HStack(spacing: Theme.Space.s) {
                if let m = model.manifest {
                    TagInserter(manifest: m, includesVoiceSwitch: false) { model.editor.insert($0) }
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.88),
                                                     .init(color: .black.opacity(0), location: 1)], startPoint: .leading, endPoint: .trailing))
                }
                Spacer(minLength: Theme.Space.s)
                Text("↩ splits · ⌘↩ done").textRole(.monoSmall, color: .textTertiary).fixedSize()
                Button("Done") { withStageAnimation(Theme.Motion.quick) { model.endEditing() } }
                    .buttonStyle(.secondary).controlSize(.small)
            }
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
        }
        .surface(.sunken, radius: Theme.Radius.m)
        .onAppear { DispatchQueue.main.async { model.editor.focus() } }
        .onExitCommand { withStageAnimation(Theme.Motion.quick) { model.endEditing() } }
    }

    private func height(for text: String) -> CGFloat {
        let rows = text.components(separatedBy: .newlines).reduce(0) { $0 + max(1, Int(ceil(Double($1.count) / 64))) }
        return min(220, max(72, CGFloat(rows) * 24 + 30))
    }
}

/// The pause after a line, drawn between it and the next. Dim at the default; lit when this line has its own.
private struct PauseGap: View {
    @Bindable var model: ConversationsModel
    let line: ConversationScript.Line
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        let own = line.pauseAfter
        let seconds = own ?? model.pauseSeconds
        HStack(spacing: Theme.Space.s) {
            Rectangle().fill(Color.hairline).frame(width: 40, height: 1)
            Button { open.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pause").font(.system(size: 7, weight: .bold))
                    Text(String(format: "%.2g s", seconds)).font(.mono(10, weight: own == nil ? .regular : .semibold))
                }
                .foregroundStyle(own == nil ? (hovered ? Color.textSecondary : Color.textTertiary) : Color.mint)
                .padding(.horizontal, 7)
                .frame(height: 17)
                .background(Capsule().fill(own == nil ? Color.clear : Color.mint.opacity(0.1)))
                .overlay(Capsule().strokeBorder(own == nil ? Color.hairline.opacity(hovered ? 1 : 0) : Color.mint.opacity(0.4), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help(own == nil ? "Pause after this line: the default. Click to set this one." : "This line's own pause. Click to change.")
            .pickerPanel(isPresented: $open, width: 260) {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    Text("Pause after line").textRole(.eyebrow)
                    StageSlider(value: Binding(get: { line.pauseAfter ?? model.pauseSeconds },
                                               set: { model.setPause($0, after: line.id) }),
                                in: 0...4, step: 0.05, defaultValue: model.pauseSeconds) { String(format: "%.2f s", $0) }
                    HStack {
                        Text(own == nil ? "Using the default" : "Default is \(String(format: "%.2g", model.pauseSeconds)) s")
                            .textRole(.caption, color: .textTertiary)
                        Spacer()
                        if own != nil {
                            Button("Use default") { model.setPause(nil, after: line.id); open = false }
                                .buttonStyle(.ghost).controlSize(.small)
                        }
                    }
                    Text("Pauses never need a re-render: lines are reused, only the gaps change.")
                        .textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(Theme.Space.m)
            }
            Rectangle().fill(Color.hairline).frame(height: 1)
        }
        .padding(.leading, 30 + Theme.Space.s)
        .padding(.trailing, Theme.Space.l)
        .frame(height: 20)
    }
}

// MARK: - Cast and staging

private struct StagingColumn: View {
    @Bindable var model: ConversationsModel
    @State private var removing: ConversationScript.Speaker?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ModelPicker(task: .tts, requires: model.usesLibraryVoices ? .cloning : [], feature: .conversation,
                            selection: $model.choice, panelWidth: 400)
                if let m = model.manifest, m.languages.count > 1 {
                    LanguagePicker(manifest: m, selection: $model.language)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Cast").textRole(.heading)
                    if !model.speakers.isEmpty { Text("\(model.speakers.count)").textRole(.mono, color: .textTertiary) }
                    Spacer()
                    Button("Add speaker", systemImage: "plus") { withStageAnimation { model.addSpeaker() } }
                        .buttonStyle(.ghost).controlSize(.small)
                }
                .padding(.top, Theme.Space.xs)
                if model.speakers.isEmpty {
                    Text("Speakers appear here when you import a script or start writing.")
                        .textRole(.caption, color: .textTertiary)
                }
                ForEach(model.speakers) { s in
                    SpeakerCard(model: model, speaker: s, onRemove: { removing = s })
                }
                if !model.sharedVoices.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle").font(.system(size: 10.5)).foregroundStyle(Color.footlight)
                        Text(model.sharedVoices.map { $0.joined(separator: " and ") }.joined(separator: "; ") + " share a voice, so they'll sound alike.")
                            .textRole(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                PerforatedDivider(notchFill: .stage).padding(.vertical, Theme.Space.xxs)
                StageSlider("Pause between lines", value: $model.pauseSeconds, in: 0...3, step: 0.05, defaultValue: 0.4) {
                    String(format: "%.2f s", $0)
                }
                .help("Silence after each line, unless a line has its own (click the pause under it).")
                if let m = model.manifest {
                    AdvancedDisclosure("Tuning", isExpanded: $model.showTuning) {
                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            HStack {
                                Text(m.name).textRole(.headline)
                                Spacer()
                                PresetsMenu(manifest: m, parameters: $model.parameters, post: $model.post)
                            }
                            ParameterPanel(manifest: m, values: $model.parameters)
                            PerforatedDivider(notchFill: .stage).padding(.vertical, Theme.Space.xxs)
                            Text("Finishing").textRole(.eyebrow)
                            PostProcessingControls(options: $model.post)
                            Toggle(isOn: $model.reuseLines) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Reuse unchanged lines").textRole(.body)
                                    Text("Off: a fresh take of every line on each render").textRole(.caption, color: .textTertiary)
                                }
                            }
                            .toggleStyle(.stage)
                        }
                        .padding(.top, Theme.Space.xs)
                    }
                }
            }
            .padding(.bottom, Theme.Space.l)
            .padding(.trailing, Theme.Space.xxs)
        }
        .scrollIndicators(.automatic)
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            if let s = removing {
                Button(model.lineCount(for: s.id) > 0 ? "Remove \(s.name) and their lines" : "Remove \(s.name)", role: .destructive) {
                    withStageAnimation { model.removeSpeaker(s.id) }
                }
            }
        } message: {
            if let s = removing, model.lineCount(for: s.id) > 0 {
                Text("\(s.name) has \(model.lineCount(for: s.id)) line\(model.lineCount(for: s.id) == 1 ? "" : "s"), which go too. Give them to someone else first to keep them.")
            }
        }
    }
}

/// A speaker: their mark, name (editable) and voice.
private struct SpeakerCard: View {
    @Bindable var model: ConversationsModel
    let speaker: ConversationScript.Speaker
    let onRemove: () -> Void
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        let tint = model.tint(speaker.id)
        let count = model.lineCount(for: speaker.id)
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Monogram(name: speaker.name, tint: tint)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.ui(13.5, weight: .semibold))
                    .foregroundStyle(.textPrimary)
                    .focused($editingName)
                    .onSubmit { model.rename(speaker.id, to: name) }
                    .onChange(of: editingName) { _, f in if !f { model.rename(speaker.id, to: name) } }
                Text(count == 0 ? "silent" : "\(count) line\(count == 1 ? "" : "s")").textRole(.monoSmall, color: .textTertiary).fixedSize()
                Button("Remove \(speaker.name)", systemImage: "xmark") { onRemove() }
                    .buttonStyle(.icon).controlSize(.small)
                    .help("Remove from the cast")
            }
            if let m = model.manifest {
                VoicePicker(manifest: m, selection: Binding(get: { model.speaker(speaker.id)?.voice ?? .automatic },
                                                            set: { model.setVoice($0, for: speaker.id) }),
                            language: model.language)
            }
        }
        .padding(Theme.Space.s)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(Color.surface)
                .overlay(alignment: .leading) { Rectangle().fill(tint).frame(width: 2.5).clipShape(shape) }
                .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
        }
        .onAppear { name = speaker.name }
        .onChange(of: speaker.name) { _, n in if !editingName { name = n } }
    }
}

/// A speaker's mark: their initials on their color.
struct Monogram: View {
    let name: String
    let tint: Color
    var size: CGFloat = 24

    var body: some View {
        Text(initials)
            .font(.ui(size * 0.42, weight: .bold))
            .foregroundStyle(Color.onTungsten)
            .frame(width: size, height: size)
            .background(Circle().fill(tint))
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." }).filter { ($0.first?.isLetter ?? false) || ($0.first?.isNumber ?? false) }
        let letters = words.prefix(2).compactMap(\.first).map(String.init)
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }
}

/// Narrow windows: the cast as a row of chips (mark, name, voice); tapping one opens the cast drawer.
private struct CastStrip: View {
    let model: ConversationsModel
    let open: () -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Theme.Space.s) {
                ForEach(model.speakers) { s in
                    Button(action: open) {
                        HStack(spacing: 6) {
                            Monogram(name: s.name, tint: model.tint(s.id), size: 20)
                            Text(s.name).font(.ui(12, weight: .semibold)).foregroundStyle(.textPrimary)
                            if let m = model.manifest {
                                Text(VoiceDescription(s.voice, manifest: m, library: model.voices).name)
                                    .font(.ui(11.5)).foregroundStyle(.textTertiary)
                            }
                        }
                        .padding(.leading, 4).padding(.trailing, 10)
                        .frame(height: 28)
                        .background(Capsule().fill(Color.surfaceRaised))
                        .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Result

private struct ResultCard: View {
    let model: ConversationsModel
    let result: ConversationsModel.Rendered
    let compact: Bool

    var body: some View {
        let generated = max(0, result.lines - result.reused)
        let summary = result.reused > 0 ? "\(generated) generated · \(result.reused) reused" : "\(result.lines) lines"
        if compact {
            HStack(spacing: Theme.Space.s) {
                Text(summary).textRole(.monoSmall, color: .mint).fixedSize()
                WaveformPlayer(track: result.track, style: .compact)
                Button("Close", systemImage: "xmark") { withStageAnimation { model.dismissResult() } }
                    .buttonStyle(.icon).controlSize(.small)
            }
        } else {
            WaveformPlayer(track: result.track)
                .accessory {
                    StatusBadge(summary, tone: result.reused > 0 ? .success : .neutral)
                        .help("Lines rendered before with the same text, voice and settings were reused as they were.")
                    Button("Close", systemImage: "xmark") { withStageAnimation { model.dismissResult() } }
                        .buttonStyle(.icon).controlSize(.small)
                }
        }
    }
}

// MARK: - First run

private struct ConversationsFirstRun: View {
    @Environment(Router.self) private var router

    var body: some View {
        EmptyState(symbol: "bubble.left.and.bubble.right", title: "No one to cast yet",
                   message: "Conversations are performed by the same models as the Studio. Download one first: Kokoro has dozens of voices to cast from; Qwen3-TTS and Chatterbox can speak in your own.") {
            Button("Open Models", systemImage: "arrow.down.circle") { router.go(.models) }
                .buttonStyle(.primary).controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Space.xl)
    }
}
