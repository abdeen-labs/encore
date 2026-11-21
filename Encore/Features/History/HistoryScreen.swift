import AppKit
import EncoreCore
import SwiftUI

/// Everything Encore has made, newest first: search as you type, kind tabs and one filter menu, a dense list with a
/// play button on every take, and a detail panel with the full script or transcript and what it was made with.
///
/// Wide windows show the list and the detail side by side; narrower ones slide the detail in over the list.
struct HistoryScreen: View {
    @Environment(AppDependencies.self) private var deps

    var body: some View {
        let model = deps.screenModel("History") { HistoryModel(deps: deps) }
        HistoryStage(model: model)
    }
}

struct HistoryStage: View {
    @Bindable var model: HistoryModel
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        ScreenScaffold(.history, scrolls: false) {
            content
        } actions: {
            if !model.isEmpty {
                SearchField(text: $model.search, prompt: "Search scripts, voices, models")
                    .frame(width: 250)
                Button {
                    withStageAnimation { if model.isSelecting { model.endSelecting() } else { model.isSelecting = true } }
                } label: {
                    Label(model.isSelecting ? "Done" : "Select", systemImage: model.isSelecting ? "checkmark" : "checklist")
                }
                .buttonStyle(.ghost)
                .help(model.isSelecting ? "Leave selection" : "Select several to export or delete (⌘-click a row also works)")
            }
        }
        .stageSheet(isPresented: Binding(get: { !model.pendingDelete.isEmpty }, set: { if !$0 { model.pendingDelete = [] } })) {
            HistoryDeleteSheet(model: model)
        }
    }

    @ViewBuilder private var content: some View {
        if model.isEmpty {
            HistoryEmptyStage()
        } else {
            GeometryReader { outer in
                let wide = outer.size.width >= 840
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    HistoryFilterBar(model: model)
                    GeometryReader { geo in
                        let detailWidth: CGFloat = min(380, max(330, geo.size.width * 0.38))
                        HStack(alignment: .top, spacing: Theme.Space.l) {
                            HistoryList(model: model, width: wide && model.focused != nil ? geo.size.width - detailWidth - Theme.Space.l : geo.size.width)
                            if wide, let item = model.focused {
                                HistoryDetail(model: model, item: item)
                                    .frame(width: detailWidth)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
                .frame(width: outer.size.width, height: outer.size.height, alignment: .topLeading)
                // Narrow windows: the detail slides in over the list (and the filters), like a drawer.
                .overlay(alignment: .topTrailing) {
                    if !wide, let item = model.focused {
                        HistoryDetail(model: model, item: item, floating: true)
                            .frame(width: min(370, outer.size.width - 40))
                            .padding(.vertical, Theme.Space.m)
                            .padding(.trailing, Theme.Space.s)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .background {
                                RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Color.surface)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                            }
                            .elevation()
                            .padding(.bottom, Theme.Space.s)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .stageAnimation(Theme.Motion.standard, value: model.focusedID)
            }
        }
    }
}

// MARK: - Filters

/// One row: the kind tabs (only the kinds the history has), one "Filter" menu for favorites, model, voice and date,
/// and, while anything narrows the list, what does and how many match.
private struct HistoryFilterBar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ViewThatFits(in: .horizontal) {
                SegmentedControl(selection: $model.kind, options: model.kindTabs) { $0.title }
                    .controlSize(.small)
                    .fixedSize()
                // Too narrow for every tab: the same choice as a menu.
                MenuPicker(selection: $model.kind, options: model.kindTabs) { $0.title }
                    .fixedSize()
            }
            .layoutPriority(1)
            HistoryFilterMenu(model: model)
            Spacer(minLength: Theme.Space.s)
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        if model.isFiltered {
            let matches = model.totalCount == 1 ? "1 match" : "\(model.totalCount) matches"
            // Whole, or just the count, or nothing: never cut to a few letters.
            ViewThatFits(in: .horizontal) {
                Text((model.menuFilterNames + [matches]).joined(separator: " · "))
                    .textRole(.caption).lineLimit(1).fixedSize()
                Text(matches).textRole(.caption).lineLimit(1).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
        }
    }
}

/// The one filter button: favorites only, model, voice and date in a native menu, with a clear item. The button
/// shows how many are on.
private struct HistoryFilterMenu: View {
    @Bindable var model: HistoryModel
    @State private var isHovered = false

    var body: some View {
        let count = model.menuFilterCount
        Menu {
            Toggle("Favorites only", isOn: $model.favoritesOnly)
            Menu(model.modelName.map { "Model: \($0)" } ?? "Model") {
                Button { model.modelID = nil } label: { menuLabel("Any model", on: model.modelID == nil) }
                if !model.facets.models.isEmpty { Divider() }
                ForEach(model.facets.models) { m in
                    Button { model.modelID = m.id } label: { menuLabel(m.name, on: model.modelID == m.id) }
                }
            }
            Menu(model.voice.map { "Voice: \($0.name)" } ?? "Voice") {
                Button { model.voice = nil } label: { menuLabel("Any voice", on: model.voice == nil) }
                if !model.facets.voices.isEmpty { Divider() }
                ForEach(model.facets.voices) { v in
                    Button { model.voice = v } label: { menuLabel(v.name, on: model.voice == v) }
                }
            }
            Menu(model.date == .any ? "Date" : "Date: \(model.date.title)") {
                ForEach(HistoryModel.DateFilter.allCases, id: \.self) { d in
                    Button { model.date = d } label: { menuLabel(d.title, on: model.date == d) }
                }
            }
            Divider()
            Button("Clear filters") { withStageAnimation(Theme.Motion.quick) { model.clearMenuFilters() } }
                .disabled(count == 0)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovered ? Color.textPrimary : .textSecondary)
                Text("Filter").textRole(.label, color: count > 0 ? .textPrimary : .textSecondary)
                if count > 0 { CountBadge(count).controlSize(.small) }
            }
            .padding(.horizontal, 10)
            .frame(height: Theme.ControlHeight.small)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                    .fill(Color.surfaceRaised.opacity(isHovered ? 1 : 0.6))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .strokeBorder(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { isHovered = $0 }
        .help(count == 0 ? "Favorites, model, voice and date" : model.menuFilterNames.joined(separator: ", "))
        .accessibilityLabel(count == 0 ? "Filter" : "Filter, \(count) on")
    }

    @ViewBuilder private func menuLabel(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

// MARK: - List

/// Items grouped by day, newest first, paging in more as the end comes into view.
private struct HistoryList: View {
    @Bindable var model: HistoryModel
    let width: CGFloat

    var body: some View {
        let items = model.items
        ZStack(alignment: .bottom) {
            if items.isEmpty, !model.isLoading {
                noMatches
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.days(items), id: \.title) { day in
                            Section {
                                ForEach(day.items) { item in
                                    HistoryRow(model: model, item: item)
                                        .onAppear { if item.id == items.last?.id { model.loadMore() } }
                                }
                            } header: {
                                DayHeader(title: day.title)
                            }
                        }
                        if model.hasMore {
                            HStack { Spacer(); ActivityIndicator(size: 12); Spacer() }.padding(.vertical, Theme.Space.m)
                        }
                    }
                    .padding(.bottom, model.isSelecting ? 72 : Theme.Space.l)
                }
                .scrollIndicators(.automatic)
            }
            if model.isSelecting {
                HistorySelectionBar(model: model)
                    .padding(.bottom, Theme.Space.s)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .stageAnimation(Theme.Motion.standard, value: model.isSelecting)
        .onDeleteCommand {
            let ids = model.selection.isEmpty ? model.focusedID.map { [$0] } ?? [] : Array(model.selection)
            if !ids.isEmpty { model.requestDelete(ids) }
        }
        .onExitCommand { if model.isSelecting { withStageAnimation { model.endSelecting() } } else { model.focusedID = nil } }
    }

    private var noMatches: some View {
        let search = model.search.trimmingCharacters(in: .whitespaces)
        return VStack {
            EmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                       message: search.isEmpty
                           ? "No item fits these filters."
                           : "No title, script, transcript, voice or model has “\(search)”\(model.store.query.hasFilters ? " with these filters" : "").",
                       style: .plain) {
                if !model.search.isEmpty { Button("Clear search") { model.search = "" }.buttonStyle(.secondary) }
                if model.store.query.hasFilters { Button("Clear filters") { withStageAnimation { model.clearFilters() } }.buttonStyle(.ghost) }
            }
            .padding(.top, Theme.Space.xxl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    struct Day { var title: String; var items: [HistoryItem] }

    static func days(_ items: [HistoryItem], now: Date = Date(), calendar: Calendar = .current) -> [Day] {
        var out: [Day] = []
        for item in items {
            let title = dayTitle(item.createdAt, now: now, calendar: calendar)
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append(Day(title: title, items: [item])) }
        }
        return out
    }

    static func dayTitle(_ date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 99
        if days < 7 { return date.formatted(.dateTime.weekday(.wide)) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)) }
        return date.formatted(.dateTime.day().month(.wide).year())
    }
}

/// "Today", "Yesterday", a weekday or a date, on a hairline.
private struct DayHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Text(title).textRole(.eyebrow)
                .fixedSize()
            Hairline()
        }
        .padding(.top, Theme.Space.l)
        .padding(.bottom, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.s)
        .accessibilityAddTraits(.isHeader)
    }
}

/// One item on one line's worth of height: a neutral kind icon, the title and a caption (search matches lit),
/// then for audio a play button with the duration, and the item's menu.
private struct HistoryRow: View {
    @Bindable var model: HistoryModel
    let item: HistoryItem
    @State private var isHovered = false

    /// Fits a play button and "12:34 / 31:14", so the menus line up down the list.
    private static let playerWidth: CGFloat = 118

    private var isFocused: Bool { model.focusedID == item.id }
    private var isSelected: Bool { model.selection.contains(item.id) }

    var body: some View {
        let terms = model.searchTerms
        let style = HistoryKindStyle(item.kind)
        HStack(alignment: .center, spacing: Theme.Space.m) {
            if model.isSelecting { checkmark }
            KindMark(kind: item.kind)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(HistoryHighlight.attributed(item.title, terms: terms))
                        .textRole(.headline)
                        .lineLimit(1)
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.textSecondary)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(HistoryHighlight.attributed(meta, terms: terms, base: .textTertiary))
                    .textRole(.caption)
                    .lineLimit(1)
                excerpt(terms)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let g = item.generation {
                    WaveformPlayer(url: g.audioURL, title: item.title, style: .minimal)
                } else {
                    Color.clear.frame(height: 1)
                }
            }
            .frame(width: Self.playerWidth, alignment: .leading)
            HistoryRowMenu(model: model, item: item)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(isFocused || isSelected ? Color.tungsten.opacity(0.07) : Color.textPrimary.opacity(isHovered ? 0.03 : 0))
                .overlay(alignment: .leading) {
                    if isFocused {
                        Capsule().fill(Color.tungsten).frame(width: 2.5).padding(.vertical, 8)
                    }
                }
                .overlay(shape.strokeBorder(isSelected ? Color.tungsten.opacity(0.35) : .clear, lineWidth: 1))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            withStageAnimation(Theme.Motion.quick) {
                model.click(item, command: flags.contains(.command), shift: flags.contains(.shift))
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu { HistoryItemMenu(model: model, item: item) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(style.name): \(item.title), \(meta)")
        .accessibilityAddTraits(isFocused || isSelected ? .isSelected : [])
    }

    private var checkmark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(isSelected ? Color.tungsten : Color.textTertiary)
            .frame(width: 14)
    }

    /// Voice · model · time for audio; model · length · time for transcripts.
    private var meta: String {
        var parts: [String] = []
        switch item.record {
        case .generation(let g):
            if let v = g.voiceName, !v.isEmpty { parts.append(v) }
            parts.append(g.modelName)
        case .transcription(let t):
            parts.append(t.modelName)
            if let d = t.transcript.duration { parts.append(Timecode.string(d, tenths: false)) }
        }
        parts.append(item.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// One line: a transcript's opening (or the part that matched), or the part of a script that matched the search.
    @ViewBuilder private func excerpt(_ terms: [String]) -> some View {
        switch item.record {
        case .transcription(let t):
            let s = HistoryHighlight.snippet(t.transcript.text.isEmpty ? t.transcript.segments.map(\.text).joined(separator: " ") : t.transcript.text, terms: terms)
            Text(HistoryHighlight.attributed(s.text, terms: terms, base: .textSecondary))
                .textRole(.caption)
                .lineLimit(1)
        case .generation(let g):
            if !terms.isEmpty, g.kind != .voiceChange {
                let s = HistoryHighlight.snippet(g.text, terms: terms)
                if s.matched, s.text.trimmingCharacters(in: .whitespaces) != item.title {
                    Text(HistoryHighlight.attributed(s.text, terms: terms, base: .textSecondary))
                        .textRole(.caption)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The "…" at the end of a row: the same actions as its context menu.
private struct HistoryRowMenu: View {
    let model: HistoryModel
    let item: HistoryItem
    @State private var isHovered = false

    var body: some View {
        Menu {
            HistoryItemMenu(model: model, item: item)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? Color.textPrimary : .textSecondary)
                .frame(width: Theme.ControlHeight.small, height: Theme.ControlHeight.small)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0))
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { isHovered = $0 }
        .help("More")
        .accessibilityLabel("More actions")
    }
}

/// The kind of an item as a small neutral icon.
struct KindMark: View {
    let kind: HistoryKind
    var size: CGFloat = 18

    var body: some View {
        let style = HistoryKindStyle(kind)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.66, weight: .regular))
            .foregroundStyle(Color.textSecondary)
            .frame(width: size, height: size)
            .help(style.name)
            .accessibilityLabel(style.name)
    }
}

/// How a kind of item is named and drawn. Kinds are told apart by icon and word, never by color.
struct HistoryKindStyle {
    var name: String
    var symbol: String

    init(_ kind: HistoryKind) {
        switch kind {
        case .speech: self.init(name: "Speech", symbol: "text.bubble")
        case .conversation: self.init(name: "Conversation", symbol: "bubble.left.and.bubble.right")
        case .voiceChange: self.init(name: "Voice change", symbol: "arrow.triangle.swap")
        case .voiceDesign: self.init(name: "Voice design", symbol: "wand.and.stars")
        case .transcription: self.init(name: "Transcript", symbol: "captions.bubble")
        }
    }

    private init(name: String, symbol: String) { self.name = name; self.symbol = symbol }
}

/// The actions on one item, shared by the row's context menu.
private struct HistoryItemMenu: View {
    let model: HistoryModel
    let item: HistoryItem
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        Button(model.focusedID == item.id ? "Hide details" : "Show details", systemImage: "sidebar.right") {
            model.focusedID = model.focusedID == item.id ? nil : item.id
        }
        Button(item.favorite ? "Unfavorite" : "Favorite", systemImage: item.favorite ? "star.slash" : "star") { model.toggleFavorite(item) }
        if model.canReuse(item) {
            Button("Reuse in Studio", systemImage: "arrow.uturn.backward") {
                if let problem = model.reuseInStudio(item) { toasts.show(problem, tone: .warning) }
            }
        }
        if model.canOpenInTranscribe(item) {
            Button("Open in Transcribe", systemImage: "captions.bubble") { model.openInTranscribe(item) }
        }
        Button(item.kind == .transcription ? "Copy transcript" : "Copy script", systemImage: "doc.on.doc") {
            model.copyText(item); toasts.show("Copied", symbol: "doc.on.doc")
        }
        Button("Show in Finder", systemImage: "folder") { model.reveal(item) }
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive) { model.requestDelete([item.id]) }
    }
}

// MARK: - Selection

/// Shown while selecting: how many, select all, export and delete. Leaving selection is the header's "Done".
private struct HistorySelectionBar: View {
    @Bindable var model: HistoryModel
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let n = model.selection.count
        HStack(spacing: Theme.Space.s) {
            Text(n == 0 ? "Click items to select them" : (n == 1 ? "1 selected" : "\(n) selected"))
                .textRole(.headline, color: n == 0 ? .textSecondary : .textPrimary)
                .monospacedDigit()
                .padding(.leading, Theme.Space.xs)
            Spacer(minLength: Theme.Space.s)
            Button("Select all") { model.selectAll() }
                .buttonStyle(.ghost).controlSize(.small)
                .disabled(n == model.items.count)
            HistoryExportMenu(model: model, items: model.selectedItems)
                .disabled(n == 0)
            Button("Delete…", systemImage: "trash") { model.requestDelete(Array(model.selection)) }
                .buttonStyle(.destructive).controlSize(.small)
                .disabled(n == 0)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 6)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).fill(Color.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous).strokeBorder(Color.hairlineStrong, lineWidth: 1))
        }
        .elevation()
    }
}

/// Exports several items into a folder: audio in the chosen format, transcripts as text.
struct HistoryExportMenu: View {
    let model: HistoryModel
    let items: [HistoryItem]
    @Environment(ToastCenter.self) private var toasts
    @Environment(ExportProgressCenter.self) private var exports: ExportProgressCenter?
    @State private var ffmpeg = true

    var body: some View {
        Menu {
            let audio = items.contains { $0.generation != nil }
            if audio {
                Section("Audio into a folder") {
                    Button("WAV (lossless)…") { run(.wav) }
                    Button("M4A (AAC)…") { run(.m4a) }
                    if ffmpeg { Button("MP3…") { run(.mp3) } } else { Text("MP3 needs ffmpeg (brew install ffmpeg)") }
                }
            } else {
                Button("Transcripts as text…") { run(.wav) }
            }
            if audio, items.contains(where: { $0.transcription != nil }) {
                Text("Transcripts are saved as text alongside")
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.button)
        .buttonStyle(.secondary)
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .task { ffmpeg = FFmpeg.isAvailable }
    }

    private func run(_ format: AudioFileFormat) {
        let chosen = items
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = chosen.count == 1 ? "Choose where to save “\(chosen[0].title)”." : "Choose a folder for \(chosen.count) items."
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let folder = panel.url else { return }
            Task { @MainActor in
                let title = chosen.count == 1 ? chosen[0].title : "\(chosen.count) items"
                let result = (try? await AudioExportActions.trackingProgress(exports, title: title) { progress in
                    await model.export(chosen, format: format, to: folder, progress: progress)
                }) ?? HistoryModel.ExportResult(written: [], failures: [], canceled: true)
                if result.canceled {
                    toasts.show(result.written.isEmpty ? "Export canceled"
                                : "Export canceled after \(result.written.count == 1 ? "1 file" : "\(result.written.count) files")", symbol: "xmark")
                } else if result.failures.isEmpty {
                    toasts.show("Saved \(result.written.count == 1 ? "1 file" : "\(result.written.count) files") to “\(folder.lastPathComponent)”", tone: .success)
                } else {
                    toasts.show("\(result.failures.count) couldn't be exported: \(result.failures[0])", tone: .danger, duration: 8)
                }
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: handler) } else { panel.begin(completionHandler: handler) }
    }
}

// MARK: - Delete

/// The confirmation: items leave history and their audio files go to the Trash, and the sheet says so.
struct HistoryDeleteSheet: View {
    let model: HistoryModel
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    private var items: [HistoryItem] {
        let ids = Set(model.pendingDelete)
        return model.items.filter { ids.contains($0.id) }
    }

    var body: some View {
        let n = model.pendingDelete.count
        let audio = items.filter { $0.generation != nil }.count
        SheetContainer(title: n == 1 ? "Delete “\(items.first?.title ?? "this item")”?" : "Delete \(n) items?",
                       subtitle: subtitle(n: n, audio: audio)) {
            Text(message(n: n, audio: audio))
                .textRole(.body, color: .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if n > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items.prefix(4)) { item in
                        HStack(spacing: Theme.Space.s) {
                            KindMark(kind: item.kind)
                            Text(item.title).textRole(.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    if items.count > 4 { Text("and \(items.count - 4) more").textRole(.caption, color: .textTertiary).padding(.leading, 26) }
                }
                .padding(Theme.Space.m)
                .surface(.sunken, radius: Theme.Radius.m)
            }
        } actions: {
            Button("Cancel") { model.pendingDelete = []; dismiss() }
                .buttonStyle(.ghost)
                .keyboardShortcut(.cancelAction)
            Button(n == 1 ? "Delete" : "Delete \(n) items", systemImage: "trash") {
                Task {
                    do {
                        let count = try await model.confirmDelete()
                        let deleted = count == 1 ? "Deleted" : "Deleted \(count) items"
                        toasts.show(audio > 0 ? "\(deleted), audio moved to the Trash" : deleted, symbol: "trash")
                    } catch {
                        toasts.show(error.localizedDescription, tone: .danger, duration: 6)
                    }
                }
                dismiss()
            }
            .buttonStyle(.destructive)
        }
    }

    /// Audio goes to the Trash; a transcript has no file, so deleting only transcripts is final.
    private func subtitle(n: Int, audio: Int) -> String {
        switch audio {
        case 0: "This can't be undone."
        case 1 where n == 1: "Its audio file goes to the Trash."
        default: "Audio files go to the Trash."
        }
    }

    private func message(n: Int, audio: Int) -> String {
        let what = n == 1 ? "It's removed from history" : "They're removed from history"
        let files: String
        switch audio {
        case 0: files = ""
        case 1 where n == 1: files = ", and its audio file is moved to the Trash, so you can still get it back from there"
        default: files = ", and \(audio == 1 ? "1 audio file is" : "\(audio) audio files are") moved to the Trash, so you can still get them back from there"
        }
        return "\(what)\(files). Voices in your library and files you exported stay as they are."
    }
}

// MARK: - Empty

/// Nothing made yet: say what lands here and lead to where things are made.
private struct HistoryEmptyStage: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing in the archive yet",
                       message: "Every take, conversation, voice change, kept design and transcript lands here, newest first, and stays on this Mac.") {
                Button("Perform in the Studio", systemImage: "text.bubble") { router.go(.studio) }
                    .buttonStyle(.primary)
                Button("Transcribe a file") { router.go(.transcribe) }
                    .buttonStyle(.ghost)
            }
            .padding(.top, Theme.Space.xxl)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
