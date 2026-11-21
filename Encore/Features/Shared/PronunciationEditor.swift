import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Presents the pronunciation list editor as a sheet.
    ///
    ///     .pronunciationSheet(isPresented: $showPronunciations)
    func pronunciationSheet(isPresented: Binding<Bool>) -> some View {
        stageSheet(isPresented: isPresented) { PronunciationEditor() }
    }
}

/// The pronunciation list over `PronunciationStore`: add, edit in place, enable/disable, case sensitivity,
/// reorder (drag the grip), delete, import/export CSV or JSON, and a "try it" line that shows any text after
/// the replacements. Present with `.pronunciationSheet(isPresented:)`.
struct PronunciationEditor: View {
    @Environment(PronunciationStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    @State private var newTerm = ""
    @State private var newReplacement = ""
    @State private var trial = "Dr. Nguyen's GIF of the Encore was huge."
    @State private var importing = false
    @State private var exportFormat: PronunciationStore.FileFormat?
    @State private var problem: String?
    @FocusState private var termFocused: Bool

    var body: some View {
        SheetContainer(title: "Pronunciations", subtitle: "Words to say differently, applied to every script before it's spoken",
                       width: 600) {
            addRow
            list
            tryIt
            if let problem {
                Banner(.danger, title: "Couldn't update the list", message: problem, onDismiss: { self.problem = nil })
            }
        } actions: {
            Button("Import…", systemImage: "square.and.arrow.down") { importing = true }
                .buttonStyle(.ghost)
            Menu {
                Button("CSV…") { exportFormat = .csv }
                Button("JSON…") { exportFormat = .json }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up").textRole(.label, color: .textSecondary)
                    .padding(.horizontal, 10).frame(height: Theme.ControlHeight.regular)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(store.entries.isEmpty)
            Spacer()
            Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .json, .plainText, .tabSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let s = try store.importFile(at: url)
                toasts.show("Imported \(s.added) new, updated \(s.updated)", tone: .success)
            } catch { problem = error.localizedDescription }
        }
        .onChange(of: exportFormat) { _, format in
            guard let format else { return }
            exportFormat = nil
            export(format)
        }
    }

    // MARK: Add

    private var addRow: some View {
        HStack(spacing: Theme.Space.s) {
            StageTextField("Word or phrase", text: $newTerm, onSubmit: add)
                .focused($termFocused)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.textTertiary)
            StageTextField("Say it like…", text: $newReplacement, onSubmit: add)
            Button("Add", systemImage: "plus", action: add)
                .buttonStyle(.secondary)
                .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty || newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !replacement.isEmpty else { return }
        mutate { try store.save(PronunciationEntry(term: term, replacement: replacement)) }
        newTerm = ""
        newReplacement = ""
        termFocused = true
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        if store.entries.isEmpty {
            VStack(spacing: 4) {
                Text("No pronunciations yet").textRole(.headline, color: .textSecondary)
                Text("Add a word and how it should sound, like “Nguyen” → “win”.").textRole(.caption, color: .textTertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 110)
            .surface(.sunken, radius: Theme.Radius.m)
        } else {
            List {
                ForEach(store.entries) { entry in
                    PronunciationRow(entry: entry) { updated in
                        mutate { try store.save(updated) }
                    } onDelete: {
                        mutate { try store.delete([entry.id]) }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                }
                .onMove { from, to in mutate { try store.move(fromOffsets: from, toOffset: to) } }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(CGFloat(store.entries.count) * 40 + 12, 260))
            .padding(.vertical, 4)
            .surface(.sunken, radius: Theme.Radius.m)
            HStack(spacing: 4) {
                Text("\(store.entries.filter(\.enabled).count) of \(store.entries.count) on").textRole(.monoSmall, color: .textTertiary)
                Spacer()
                Text("Longer terms win; drag the grip to reorder.").textRole(.caption, color: .textTertiary)
            }
        }
    }

    // MARK: Try it

    private var tryIt: some View {
        let applied = PronunciationApplier(entries: store.entries).apply(to: trial)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Try it").textRole(.eyebrow)
            StageTextField("Type a sentence to test", text: $trial, symbol: "text.cursor")
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.textTertiary)
                Text(applied.isEmpty ? " " : applied)
                    .textRole(.body, color: applied == trial ? .textSecondary : .textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)
        }
    }

    // MARK: Files

    private func export(_ format: PronunciationStore.FileFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Pronunciations.\(format.rawValue)"
        panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mutate {
            try store.export(to: url, format: format)
            toasts.show("Exported \(store.entries.count) pronunciations", tone: .success)
        }
    }

    private func mutate(_ change: () throws -> Void) {
        do { try change(); problem = nil } catch { problem = error.localizedDescription }
    }
}

/// One editable row: on/off, term, replacement, case-sensitive, delete. Edits commit on Return or leaving the field.
private struct PronunciationRow: View {
    let entry: PronunciationEntry
    let onChange: (PronunciationEntry) -> Void
    let onDelete: () -> Void

    @State private var term = ""
    @State private var replacement = ""
    @State private var isHovered = false
    @FocusState private var focus: Field?
    private enum Field { case term, replacement }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Color.textSecondary : .textTertiary.opacity(0.6))
                .frame(width: 14)
                .help("Drag to reorder")
            Toggle("", isOn: Binding(get: { entry.enabled }, set: { var e = entry; e.enabled = $0; onChange(e) }))
                .toggleStyle(.stage)
                .labelsHidden()
                .frame(width: 34)
                .help(entry.enabled ? "On" : "Off")
            field($term, placeholder: "Term", which: .term)
            Image(systemName: "arrow.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.textTertiary)
            field($replacement, placeholder: "Replacement", which: .replacement)
            Button {
                var e = entry; e.caseSensitive.toggle(); onChange(e)
            } label: {
                Text("Aa")
                    .textRole(.label, color: entry.caseSensitive ? .textPrimary : .textTertiary)
                    .frame(width: 28, height: 22)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(entry.caseSensitive ? Color.surfaceRaised : .clear))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).strokeBorder(entry.caseSensitive ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(entry.caseSensitive ? "Case-sensitive: only this exact capitalization" : "Any capitalization")
            .accessibilityLabel("Case-sensitive")
            .accessibilityValue(entry.caseSensitive ? "On" : "Off")
            Button("Delete \(entry.term)", systemImage: "trash", action: onDelete)
                .buttonStyle(.icon(tone: .danger))
                .controlSize(.small)
                .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.s).fill(Color.textPrimary.opacity(isHovered ? 0.035 : 0)))
        .opacity(entry.enabled ? 1 : 0.55)
        .onHover { isHovered = $0 }
        .onAppear { term = entry.term; replacement = entry.replacement }
        .onChange(of: entry) { _, e in
            if focus != .term { term = e.term }
            if focus != .replacement { replacement = e.replacement }
        }
        .onChange(of: focus) { old, _ in if old != nil { commit() } }
    }

    private func field(_ text: Binding<String>, placeholder: String, which: Field) -> some View {
        TextField(placeholder, text: text, prompt: Text(placeholder).foregroundStyle(Color.textTertiary))
            .textFieldStyle(.plain)
            .textRole(.body)
            .focused($focus, equals: which)
            .onSubmit(commit)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(focus == which ? Color.surfaceSunken : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xs).strokeBorder(focus == which ? Color.tungsten.opacity(0.6) : .clear, lineWidth: 1))
    }

    private func commit() {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !r.isEmpty else { term = entry.term; replacement = entry.replacement; return }
        guard t != entry.term || r != entry.replacement else { return }
        var e = entry
        e.term = t
        e.replacement = r
        onChange(e)
    }
}
