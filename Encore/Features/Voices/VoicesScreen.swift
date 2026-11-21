import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// The voice library: a playbill of voice cards (search, filter by origin and tag, sort), an inspector to edit one,
/// multi-select for export and delete, and `.encorevoice` import by button or by dropping files on the screen.
struct VoicesScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("Voices") { VoicesModel(deps: deps) }
        VoicesStage(model: model)
    }
}

struct VoicesStage: View {
    @Bindable var model: VoicesModel
    @Environment(AppDependencies.self) private var deps
    @Environment(VoiceLibrary.self) private var library
    @Environment(ToastCenter.self) private var toasts
    @State private var width: CGFloat = 1000
    @State private var isDropTargeted = false

    private var inspectorBeside: Bool { width >= 860 }

    var body: some View {
        ScreenScaffold(.voices, scrolls: false) {
            if library.voices.isEmpty {
                empty
            } else {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    browser
                    if inspectorBeside, let voice = model.focusedVoice {
                        inspector(voice)
                            .frame(width: 340)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .trailing) {
                    if !inspectorBeside, let voice = model.focusedVoice {
                        inspector(voice)
                            .frame(width: 340)
                            .padding(Theme.Space.m)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Color.surface)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.hairlineStrong))
                            }
                            .elevation()
                            .padding(.bottom, Theme.Space.l)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
        } actions: {
            headerActions
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.Space.screenInset } action: { width = $0 }
        .overlay { if isDropTargeted { dropOverlay } }
        .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) } isTargeted: { isDropTargeted = $0 }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.encoreVoice], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importFiles(urls) } }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !model.pendingDelete.isEmpty }, set: { if !$0 { model.pendingDelete = [] } })) {
            Button("Move to Trash", role: .destructive) {
                let n = model.delete(model.pendingDelete)
                model.pendingDelete = []
                toasts.show(n == 1 ? "Moved to the Trash" : "\(n) voices moved to the Trash", symbol: "trash")
            }
        } message: {
            Text("The voice files go to the Trash, so you can still get them back from there.")
        }
        .onChange(of: library.voices) { _, _ in model.prune() }
        .onChange(of: model.exportNote) { _, note in
            if let note { toasts.show(note, tone: note.hasPrefix("Export failed") ? .danger : .success); model.exportNote = nil }
        }
        .stageAnimation(Theme.Motion.standard, value: model.focused)
        .stageAnimation(Theme.Motion.quick, value: isDropTargeted)
    }

    private var deleteTitle: String {
        let n = model.pendingDelete.count
        if n == 1, let v = library.voice(model.pendingDelete[0]) { return "Move “\(v.name)” to the Trash?" }
        return "Move \(n) voices to the Trash?"
    }

    @ViewBuilder private var headerActions: some View {
        if let busy = model.busy {
            HStack(spacing: 6) { ActivityIndicator(size: 12); Text(busy).textRole(.caption) }
        }
        Button("Import…", systemImage: "square.and.arrow.down") { model.showImporter = true }
            .buttonStyle(.secondary).controlSize(.small)
            .help("Import .encorevoice files (or drop them anywhere on this screen)")
        if !library.voices.isEmpty {
            Menu {
                Button("Clone a voice", systemImage: "mic") { deps.router.go(.clone) }
                Button("Design a voice", systemImage: "wand.and.stars") { deps.router.go(.design) }
            } label: {
                Label("New voice", systemImage: "plus")
                    .font(.ui(12, weight: .semibold))
                    .foregroundStyle(Color.onTungsten)
                    .padding(.horizontal, 12)
                    .frame(height: Theme.ControlHeight.small)
                    .background(Capsule().fill(Color.tungsten))
                    .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }

    // MARK: Browser

    private var browser: some View {
        let list = model.visible
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            toolbar
            if !library.allTags.isEmpty { tagRow }
            if let report = model.importReport { ImportReportBanner(report: report) { withStageAnimation { model.importReport = nil } } }
            if !library.problems.isEmpty {
                Banner(.warning, title: "Some voice folders couldn't be read",
                       message: library.problems.prefix(3).joined(separator: "\n"))
            }
            if model.selection.count > 1 { bulkBar }
            if list.isEmpty {
                VStack(spacing: Theme.Space.s) {
                    Text("No voices match").textRole(.headline, color: .textSecondary)
                    Button("Clear filters", action: model.clearFilters).buttonStyle(.ghost).controlSize(.small)
                }
                .frame(maxWidth: .infinity).padding(.top, Theme.Space.xxl)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 236, maximum: 380), spacing: Theme.Space.l)],
                              alignment: .leading, spacing: Theme.Space.l) {
                        ForEach(list) { voice in
                            VoiceCard(voice: voice, reference: library.referenceAudioURL(for: voice.id),
                                      isFocused: model.focused == voice.id,
                                      isSelected: model.selection.count > 1 && model.selection.contains(voice.id),
                                      showsCheck: model.selection.count > 1,
                                      onClick: { model.click(voice.id, modifiers: NSEvent.modifierFlags, in: list) },
                                      onToggle: { model.toggle(voice.id) })
                                .contextMenu { contextMenu(voice) }
                        }
                    }
                    .padding(.vertical, Theme.Space.xs)
                    .padding(.bottom, Theme.Space.xl)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                SearchField(text: $model.query, prompt: "Search names, tags, words").frame(minWidth: 180, maxWidth: 300)
                originControl
                Spacer(minLength: 0)
                sortMenu
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.m) {
                    SearchField(text: $model.query, prompt: "Search names, tags, words")
                    sortMenu
                }
                originControl
            }
        }
    }

    private var originControl: some View {
        SegmentedControl(selection: $model.origin, options: VoicesModel.OriginFilter.allCases) { o in
            let n = model.count(o)
            return o == .all ? "All \(n)" : (n > 0 ? "\(o.rawValue) \(n)" : o.rawValue)
        }
        .controlSize(.small)
    }

    private var sortMenu: some View {
        MenuPicker(selection: $model.sort, options: VoicesModel.Sort.allCases) { $0.rawValue }
            .frame(width: 150)
    }

    private var tagRow: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Text("Tags").textRole(.eyebrow)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(library.allTags, id: \.self) { tag in
                        Chip(tag, isSelected: Binding(get: { model.tags.contains(tag) },
                                                      set: { on in if on { model.tags.insert(tag) } else { model.tags.remove(tag) } }))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.92),
                                         .init(color: .black.opacity(0), location: 1)], startPoint: .leading, endPoint: .trailing))
            if !model.tags.isEmpty {
                Button("Clear") { model.tags = [] }.buttonStyle(.ghost).controlSize(.small)
            }
        }
    }

    private var bulkBar: some View {
        let ids = Array(model.selection)
        return HStack(spacing: Theme.Space.m) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tungsten)
            Text("\(ids.count) voices selected").textRole(.headline)
            Spacer(minLength: Theme.Space.s)
            Button("Export…", systemImage: "square.and.arrow.up") { model.exportWithPanel(ids) }
                .buttonStyle(.secondary).controlSize(.small)
            Button("Move to Trash…", systemImage: "trash") { model.pendingDelete = ids }
                .buttonStyle(.destructive).controlSize(.small)
            Button("Done") { model.selection = [] ; model.focused = nil }
                .buttonStyle(.ghost).controlSize(.small)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).fill(Color.tungsten.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Color.tungsten.opacity(0.3)))
        }
    }

    @ViewBuilder private func contextMenu(_ voice: Voice) -> some View {
        Button("Use in Studio", systemImage: "text.bubble") { cast(voice) }
        Button("Duplicate", systemImage: "plus.square.on.square") { Task { _ = await model.duplicate(voice.id) } }
        Button("Export…", systemImage: "square.and.arrow.up") {
            model.exportWithPanel(model.selection.contains(voice.id) && model.selection.count > 1 ? Array(model.selection) : [voice.id])
        }
        Divider()
        Button("Move to Trash…", systemImage: "trash", role: .destructive) {
            model.pendingDelete = model.selection.contains(voice.id) && model.selection.count > 1 ? Array(model.selection) : [voice.id]
        }
    }

    private func cast(_ voice: Voice) {
        if let note = deps.castInStudio(voice.id) { toasts.show(note, tone: .warning) }
        else { toasts.show("\(voice.name) is cast in Studio", tone: .success, symbol: "person.wave.2") }
    }

    private func inspector(_ voice: Voice) -> some View {
        VoiceInspector(voice: voice, reference: library.referenceAudioURL(for: voice.id),
                       onClose: { model.focus(nil) },
                       onCast: { cast(voice) },
                       onDuplicate: { Task { _ = await model.duplicate(voice.id) } },
                       onExport: { model.exportWithPanel([voice.id]) },
                       onDelete: { model.pendingDelete = [voice.id] })
            .id(voice.id)
    }

    // MARK: Empty and drop

    private var empty: some View {
        VStack(spacing: Theme.Space.l) {
            EmptyState(symbol: "person.wave.2", title: "No one in the company yet",
                       message: "Clone one from a recording or design one from a description.") {
                Button("Clone a voice", systemImage: "mic") { deps.router.go(.clone) }.buttonStyle(.primary).controlSize(.large)
                Button("Design a voice", systemImage: "wand.and.stars") { deps.router.go(.design) }.buttonStyle(.secondary).controlSize(.large)
            }
            if let report = model.importReport {
                ImportReportBanner(report: report) { withStageAnimation { model.importReport = nil } }.frame(maxWidth: 560)
            }
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "square.and.arrow.down").foregroundStyle(.textTertiary)
                Text("Have an .encorevoice file? Drop it here or").textRole(.caption, color: .textTertiary)
                Button("import it") { model.showImporter = true }.buttonStyle(.ghost).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dropOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
        return ZStack {
            shape.fill(Color.backdrop.opacity(0.78))
            shape.strokeBorder(Color.tungsten, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 8]))
            VStack(spacing: Theme.Space.s) {
                Image(systemName: "person.wave.2").font(.system(size: 30, weight: .light)).foregroundStyle(Color.tungsten)
                    .glow(.tungsten, radius: 12, intensity: 0.5)
                Text("Drop to add to the company").textRole(.title)
                Text(".encorevoice files are imported · audio goes to Clone").textRole(.caption)
            }
        }
        .padding(Theme.Space.l)
        .allowsHitTesting(false)
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let voiceFiles = urls.filter { $0.pathExtension.lowercased() == VoiceLibrary.fileExtension }
        if !voiceFiles.isEmpty {
            Task { await model.importFiles(voiceFiles) }
            return true
        }
        let media = urls.first { url in
            guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
            return CloneMedia.types.contains { t.conforms(to: $0) }
        }
        if let media {
            let clone = deps.screenModel("Clone") { CloneModel(deps: deps) }
            Task { await clone.load(media) }
            deps.router.go(.clone)
            return true
        }
        return false
    }
}

// MARK: - Import report

struct ImportReportBanner: View {
    let report: VoicesModel.ImportReport
    let onDismiss: () -> Void

    var body: some View {
        let ok = report.refused.isEmpty
        Banner(ok ? .success : (report.imported.isEmpty ? .danger : .warning), title: title, message: message, onDismiss: onDismiss)
    }

    private var title: String {
        let n = report.imported.count
        if n == 0 { return report.refused.count == 1 ? "Nothing was imported" : "None of the files were imported" }
        return n == 1 ? "Imported “\(report.imported[0].name)”" : "Imported \(n) voices"
    }

    private var message: String? {
        var lines: [String] = []
        if report.imported.count > 1 { lines.append(report.imported.map(\.name).joined(separator: ", ")) }
        for r in report.refused { lines.append(r.reason.contains(r.file) ? r.reason : "\(r.file): \(r.reason)") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
