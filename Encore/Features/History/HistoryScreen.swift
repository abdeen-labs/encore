import AppKit
import EncoreCore
import SwiftUI

/// Everything Encore has made, newest first: search as you type, a few quiet filters, a waveform player on every
/// take, and a detail panel with the full script or transcript and every setting it was made with.
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
                        HistoryDetail(model: model, item: item, compactPlayer: true)
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

/// Kind tabs (only the kinds the history has), then favorites, model, voice and date as quiet chips.
private struct HistoryFilterBar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.m) {
                kinds
                chips
                Spacer(minLength: 0)
                summary
            }
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                kinds
                HStack(spacing: Theme.Space.m) { chips; Spacer(minLength: 0); summary }
            }
        }
    }

    private var kinds: some View {
        SegmentedControl(selection: $model.kind, options: model.kindTabs) { k in
            // Counts are of the whole history, so they'd mislead while searching or filtering.
            let n = model.isFiltered ? 0 : model.count(k)
            return k == .all ? "All" : (n > 0 ? "\(k.title) \(n)" : k.title)
        }
        .controlSize(.small)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Favorites", symbol: model.favoritesOnly ? "star.fill" : "star", isActive: model.favoritesOnly) {
                model.favoritesOnly.toggle()
            }
            FilterMenu(title: model.modelName ?? "Model", symbol: "cpu", isActive: model.modelID != nil,
                       onClear: { model.modelID = nil }) {
                ForEach(model.facets.models) { m in
                    Button { model.modelID = m.id } label: { menuLabel("\(m.name)  ·  \(m.count)", on: model.modelID == m.id) }
                }
            }
            FilterMenu(title: model.voice?.name ?? "Voice", symbol: "person.wave.2", isActive: model.voice != nil,
                       onClear: { model.voice = nil }) {
                if model.facets.voices.isEmpty { Text("No voices yet") }
                ForEach(model.facets.voices) { v in
                    Button { model.voice = v } label: { menuLabel("\(v.name)  ·  \(v.count)", on: model.voice == v) }
                }
            }
            FilterMenu(title: model.date == .any ? "Date" : model.date.title, symbol: "calendar", isActive: model.date != .any,
                       onClear: { model.date = .any }) {
                ForEach(HistoryModel.DateFilter.allCases.filter { $0 != .any }, id: \.self) { d in
                    Button { model.date = d } label: { menuLabel(d.title, on: model.date == d) }
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder private func menuLabel(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    @ViewBuilder private var summary: some View {
        HStack(spacing: Theme.Space.s) {
            if model.isFiltered {
                Text(model.totalCount == 1 ? "1 match" : "\(model.totalCount) matches")
                    .textRole(.monoSmall, color: model.totalCount == 0 ? .footlight : .textSecondary)
                if model.store.query.hasFilters {
                    Button("Clear") { withStageAnimation { model.clearFilters() } }
                        .buttonStyle(.ghost).controlSize(.small)
                }
            } else {
                Text(model.totalCount == 1 ? "1 item" : "\(model.totalCount) items").textRole(.monoSmall, color: .textTertiary)
            }
        }
        .fixedSize()
    }
}

/// A toggle in the filter row: a capsule that lights tungsten when on.
private struct FilterChip: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: { withStageAnimation(Theme.Motion.quick, action) }) {
            FilterCapsule(title: title, symbol: symbol, isActive: isActive, isHovered: isHovered, trailing: nil)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A filter with choices: a native menu behind a capsule; when set, the capsule shows the choice and a clear button.
private struct FilterMenu<Items: View>: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let onClear: () -> Void
    @ViewBuilder var items: Items
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                items
            } label: {
                FilterCapsule(title: title, symbol: symbol, isActive: isActive, isHovered: isHovered,
                              trailing: isActive ? nil : "chevron.down")
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            if isActive {
                Button("Clear \(title)", systemImage: "xmark") { withStageAnimation(Theme.Motion.quick, onClear) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.tungsten)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
                    .padding(.leading, -24)
                    .help("Clear")
            }
        }
        .onHover { isHovered = $0 }
    }
}

private struct FilterCapsule: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let isHovered: Bool
    let trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(title).font(.ui(11.5, weight: isActive ? .semibold : .medium)).lineLimit(1)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 7.5, weight: .bold)).foregroundStyle(Color.textTertiary)
            } else if isActive, symbol != "star.fill" {
                Color.clear.frame(width: 12, height: 1)  // room for the clear button
            }
        }
        .foregroundStyle(isActive ? Color.tungsten : (isHovered ? Color.textPrimary : Color.textSecondary))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background {
            Capsule().fill(isActive ? Color.tungsten.opacity(0.12) : Color.surfaceRaised.opacity(isHovered ? 1 : 0.6))
                .overlay(Capsule().strokeBorder(isActive ? Color.tungsten.opacity(0.45) : (isHovered ? Color.hairlineStrong : Color.hairline), lineWidth: 1))
        }
        .contentShape(Capsule())
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
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Self.days(items), id: \.title) { day in
                            Section {
                                ForEach(day.items) { item in
                                    HistoryRow(model: model, item: item, inlinePlayer: width >= 520, playerWidth: min(320, max(220, width * 0.44)))
                                        .onAppear { if item.id == items.last?.id { model.loadMore() } }
                                }
                            } header: {
                                DayHeader(title: day.title, count: day.items.count)
                            }
                        }
                        if model.hasMore {
                            HStack { Spacer(); ActivityIndicator(size: 12); Spacer() }.padding(.vertical, Theme.Space.m)
                        }
                    }
                    .padding(.bottom, model.selection.isEmpty ? Theme.Space.l : 72)
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
        VStack {
            EmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                       message: model.search.trimmingCharacters(in: .whitespaces).isEmpty
                           ? "No item fits these filters."
                           : "No title, script, transcript, voice or model has “\(model.search.trimmingCharacters(in: .whitespaces))”\(model.store.query.hasFilters ? " with these filters" : "").") {
                if !model.search.isEmpty { Button("Clear search") { model.search = "" }.buttonStyle(.secondary) }
                if model.store.query.hasFilters { Button("Clear filters") { withStageAnimation { model.clearFilters() } }.buttonStyle(.ghost) }
            }
            Spacer()
        }
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

private struct DayHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title).textRole(.eyebrow, color: .textSecondary)
            Text("\(count)").textRole(.monoSmall, color: .textTertiary)
            Rectangle().fill(Color.hairline).frame(height: 1)
        }
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.xs)
    }
}

/// One item: kind mark, title and details (search matches lit), and for audio a compact waveform player.
private struct HistoryRow: View {
    @Bindable var model: HistoryModel
    let item: HistoryItem
    let inlinePlayer: Bool
    let playerWidth: CGFloat
    @State private var isHovered = false
    @Environment(ToastCenter.self) private var toasts

    private var isFocused: Bool { model.focusedID == item.id }
    private var isSelected: Bool { model.selection.contains(item.id) }

    var body: some View {
        let terms = model.searchTerms
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                if model.isSelecting { checkmark }
                KindMark(kind: item.kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(HistoryHighlight.attributed(item.title, terms: terms))
                            .font(.ui(13, weight: .semibold)).lineLimit(1)
                        if item.favorite {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color.tungsten)
                                .accessibilityLabel("Favorite")
                        }
                    }
                    Text(HistoryHighlight.attributed(meta, terms: terms, base: .textTertiary))
                        .font(.ui(11)).lineLimit(1)
                    snippet(terms)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if inlinePlayer, let g = item.generation { player(g).frame(width: playerWidth) }
            }
            if !inlinePlayer, let g = item.generation {
                player(g).padding(.leading, (model.isSelecting ? 26 : 0) + 30 + Theme.Space.m)
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(isFocused || isSelected ? Color.tungsten.opacity(0.07) : Color.textPrimary.opacity(isHovered ? 0.03 : 0))
                .overlay(alignment: .leading) {
                    if isFocused {
                        Capsule().fill(Color.tungsten).frame(width: 2.5).padding(.vertical, 8)
                            .glow(.tungsten, radius: 4, intensity: 0.5)
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
        .accessibilityLabel("\(item.title), \(meta)")
        .accessibilityAddTraits(isFocused || isSelected ? .isSelected : [])
    }

    private var checkmark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(isSelected ? Color.tungsten : Color.textTertiary)
            .frame(width: 14)
    }

    private var meta: String {
        var parts: [String] = []
        switch item.record {
        case .generation(let g):
            if let v = g.voiceName, !v.isEmpty { parts.append(v) }
            parts.append(g.modelName)
            if g.kind == .voiceChange { parts.append("from \(g.text)") }
        case .transcription(let t):
            parts.append(t.modelName)
            if let d = t.transcript.duration { parts.append("\(Timecode.string(d, tenths: false)) of audio") }
            if let l = t.transcript.language { parts.append(Locale.current.localizedString(forLanguageCode: l) ?? l) }
        }
        parts.append(item.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: " · ")
    }

    /// Transcripts always show their opening; scripts show the part that matched the search.
    @ViewBuilder private func snippet(_ terms: [String]) -> some View {
        switch item.record {
        case .transcription(let t):
            let s = HistoryHighlight.snippet(t.transcript.text.isEmpty ? t.transcript.segments.map(\.text).joined(separator: " ") : t.transcript.text, terms: terms)
            Text(HistoryHighlight.attributed(s.text, terms: terms, base: .textSecondary))
                .font(.ui(11.5)).lineLimit(2).padding(.top, 1)
        case .generation(let g):
            if !terms.isEmpty, g.kind != .voiceChange {
                let s = HistoryHighlight.snippet(g.text, terms: terms)
                if s.matched, s.text.trimmingCharacters(in: .whitespaces) != item.title {
                    Text(HistoryHighlight.attributed(s.text, terms: terms, base: .textSecondary))
                        .font(.ui(11.5)).lineLimit(2).padding(.top, 1)
                }
            }
        }
    }

    private func player(_ g: GenerationRecord) -> some View {
        WaveformPlayer(url: g.audioURL, title: item.title, subtitle: [g.voiceName, g.modelName].compactMap { $0 }.joined(separator: " · "),
                       style: .compact)
    }
}

/// The kind of an item as a small lit tile.
struct KindMark: View {
    let kind: HistoryKind
    var size: CGFloat = 30

    var body: some View {
        let style = HistoryKindStyle(kind)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(style.color)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).fill(style.color.opacity(0.1))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous).strokeBorder(style.color.opacity(0.22), lineWidth: 1))
            }
            .help(style.name)
            .accessibilityLabel(style.name)
    }
}

struct HistoryKindStyle {
    var name: String
    var symbol: String
    var color: Color

    init(_ kind: HistoryKind) {
        switch kind {
        case .speech: self.init(name: "Speech", symbol: "text.bubble", color: .tungsten)
        case .conversation: self.init(name: "Conversation", symbol: "bubble.left.and.bubble.right", color: .mint)
        case .voiceChange: self.init(name: "Voice change", symbol: "arrow.triangle.swap", color: .gel)
        case .voiceDesign: self.init(name: "Voice design", symbol: "wand.and.stars", color: .gel)
        case .transcription: self.init(name: "Transcript", symbol: "captions.bubble", color: .textSecondary)
        }
    }

    private init(name: String, symbol: String, color: Color) { self.name = name; self.symbol = symbol; self.color = color }
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

/// Shown while selecting: how many, select all, export and delete.
private struct HistorySelectionBar: View {
    @Bindable var model: HistoryModel
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        let n = model.selection.count
        HStack(spacing: Theme.Space.s) {
            Text(n == 0 ? "Click items to select them" : (n == 1 ? "1 selected" : "\(n) selected"))
                .font(.ui(12, weight: .semibold)).foregroundStyle(n == 0 ? Color.textSecondary : .textPrimary)
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
            Button("Done") { withStageAnimation { model.endSelecting() } }
                .buttonStyle(.secondary).controlSize(.small)
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
                toasts.show("Exporting \(chosen.count == 1 ? "1 item" : "\(chosen.count) items")…", symbol: "square.and.arrow.up", duration: 60)
                let result = await model.export(chosen, format: format, to: folder)
                if result.failures.isEmpty {
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

/// The confirmation: history deletes are permanent (audio files included), and the sheet says so.
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
                       subtitle: "This can't be undone.") {
            Text(message(n: n, audio: audio))
                .textRole(.body, color: .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if n > 1 {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(items.prefix(4)) { item in
                        HStack(spacing: Theme.Space.s) {
                            KindMark(kind: item.kind, size: 20)
                            Text(item.title).textRole(.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    if items.count > 4 { Text("and \(items.count - 4) more").textRole(.caption, color: .textTertiary).padding(.leading, 28) }
                }
                .padding(Theme.Space.m)
                .surface(.sunken, radius: Theme.Radius.m)
            }
        } actions: {
            Button("Cancel") { model.pendingDelete = []; dismiss() }
                .buttonStyle(.ghost)
                .keyboardShortcut(.cancelAction)
            Button(n == 1 ? "Delete permanently" : "Delete \(n) permanently", systemImage: "trash") {
                Task {
                    do {
                        let count = try await model.confirmDelete()
                        toasts.show(count == 1 ? "Deleted" : "Deleted \(count) items", symbol: "trash")
                    } catch {
                        toasts.show(error.localizedDescription, tone: .danger, duration: 6)
                    }
                }
                dismiss()
            }
            .buttonStyle(.destructive)
        }
    }

    private func message(n: Int, audio: Int) -> String {
        let what = n == 1 ? "It's removed from history" : "They're removed from history"
        let files: String
        switch audio {
        case 0: files = ""
        case 1 where n == 1: files = ", and its audio file is deleted from this Mac"
        default: files = ", and \(audio == 1 ? "1 audio file is" : "\(audio) audio files are") deleted from this Mac"
        }
        return "\(what)\(files). Nothing goes to the Trash. Voices in your library and files you exported stay as they are."
    }
}

// MARK: - Empty

/// Nothing made yet: say what lands here and lead to where things are made.
private struct HistoryEmptyStage: View {
    @Environment(Router.self) private var router

    var body: some View {
        VStack {
            EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing in the archive yet",
                       message: "Every take, conversation, voice change, kept voice design and transcript lands here, newest first. It stays on this Mac, searchable, with the settings each was made with.") {
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
