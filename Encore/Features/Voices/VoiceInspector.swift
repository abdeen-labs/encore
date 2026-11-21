import EncoreCore
import SwiftUI

/// One voice, open for editing: name, tags, language, transcript, notes, the design prompt for designed voices,
/// when consent was confirmed, and the actions (use in Studio, duplicate, export, move to Trash).
/// Edits are a draft until saved; switching to another voice or closing saves them.
struct VoiceInspector: View {
    let voice: Voice
    let reference: URL?
    var onClose: () -> Void
    var onCast: () -> Void
    var onDuplicate: () -> Void
    var onExport: () -> Void
    var onDelete: () -> Void

    @Environment(VoiceLibrary.self) private var library
    @Environment(AppDependencies.self) private var deps
    @Environment(ToastCenter.self) private var toasts
    @State private var draft: Voice?

    private var working: Voice { draft ?? voice }
    private var isDirty: Bool { draft.map { $0 != voice } ?? false }

    private func binding<T>(_ path: WritableKeyPath<Voice, T>) -> Binding<T> {
        Binding { working[keyPath: path] } set: { v in
            var d = draft ?? voice
            d[keyPath: path] = v
            draft = d
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    header
                    if let reference {
                        WaveformPlayer(url: reference, title: "Reference clip",
                                       subtitle: String(format: "%.1f s", voice.duration))
                    }
                    actions
                    field("Tags") { TagEditor(tags: binding(\.tags), suggestions: library.allTags) }
                    VoiceLanguageMenu(language: binding(\.language))
                    field("Transcript", caption: "Exactly what the reference clip says. Models that read along use it.") {
                        ScriptEditor(text: binding(\.transcript), placeholder: "What the clip says…", minHeight: 74, showsStats: false)
                    }
                    if voice.origin == .designed || voice.designPrompt != nil { designPrompt }
                    field("Notes") {
                        ScriptEditor(text: binding(\.notes), placeholder: "Where it's from, how to direct it…", minHeight: 56, showsStats: false)
                    }
                    facts
                }
                .padding(.trailing, Theme.Space.xs)
                .padding(.bottom, Theme.Space.l)
            }
            .scrollIndicators(.automatic)
            if isDirty { saveBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .stageAnimation(Theme.Motion.quick, value: isDirty)
        .onDisappear(perform: commit)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: voice.origin.symbol).font(.system(size: 9.5, weight: .bold))
                Text("\(voice.origin.label) voice").textRole(.eyebrow, color: .tungsten.opacity(0.8))
                Spacer()
                Button("Close", systemImage: "xmark", action: onClose).buttonStyle(.icon).controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .foregroundStyle(Color.tungsten.opacity(0.8))
            TextField("Name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(.display(26))
                .foregroundStyle(.textPrimary)
                .onSubmit(commit)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.s) {
            Button("Use in Studio", systemImage: "text.bubble") { commit(); onCast() }
                .buttonStyle(.primary).controlSize(.small)
            Spacer(minLength: 0)
            Button("Duplicate", systemImage: "plus.square.on.square") { commit(); onDuplicate() }
                .buttonStyle(.icon).controlSize(.small).help("Duplicate")
            Button("Export…", systemImage: "square.and.arrow.up") { commit(); onExport() }
                .buttonStyle(.icon).controlSize(.small).help("Export as .encorevoice")
            Button("Move to Trash…", systemImage: "trash", action: onDelete)
                .buttonStyle(.icon(tone: .danger)).controlSize(.small).help("Move to Trash")
        }
    }

    private var designPrompt: some View {
        field("Designed from") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(voice.designPrompt.map { "“\($0)”" } ?? "No description was kept.")
                    .font(.display(15, italic: true)).foregroundStyle(.textSecondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let prompt = voice.designPrompt {
                    Button("Design more like this", systemImage: "wand.and.stars") {
                        let design = deps.screenModel("Design") { DesignModel(deps: deps) }
                        design.description = prompt
                        deps.router.go(.design)
                    }
                    .buttonStyle(.ghost).controlSize(.small)
                }
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.sunken, radius: Theme.Radius.m)
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 2) {
            PerforatedDivider().padding(.bottom, Theme.Space.s)
            KeyValueRow("Length", value: String(format: "%.1f s", voice.duration))
            KeyValueRow("Added") {
                Text(VoiceDates.compact(voice.createdAt)).textRole(.mono).textSelection(.enabled)
                    .help(voice.createdAt.formatted(date: .complete, time: .shortened))
            }
            if let id = voice.sourceModelID {
                KeyValueRow("Made with", value: deps.catalog.model(id)?.name ?? id)
            }
            KeyValueRow("Consent") {
                Text(consentText).textRole(.mono, color: voice.consentConfirmedAt != nil ? .mint : .textTertiary)
                    .help(voice.consentConfirmedAt.map { "Confirmed " + $0.formatted(date: .complete, time: .shortened) } ?? "")
            }
        }
    }

    private var consentText: String {
        if let at = voice.consentConfirmedAt { return "Confirmed " + VoiceDates.day(at) }
        return voice.needsSpeakerConsent ? "Not recorded" : "Not needed"
    }

    private var saveBar: some View {
        HStack(spacing: Theme.Space.s) {
            Circle().fill(Color.footlight).frame(width: 6, height: 6).glow(.footlight, radius: 4, intensity: 0.5)
            Text("Unsaved changes").textRole(.caption)
            Spacer()
            Button("Revert") { draft = nil }.buttonStyle(.ghost).controlSize(.small)
            Button("Save", action: commit).buttonStyle(.primary).controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.top, Theme.Space.s)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }

    private func field<C: View>(_ title: String, caption: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).textRole(.label, color: .textSecondary)
            content()
            if let caption { Text(caption).textRole(.caption, color: .textTertiary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func commit() {
        guard var d = draft, d != voice, library.voice(voice.id) != nil else { draft = nil; return }
        if d.name.trimmingCharacters(in: .whitespaces).isEmpty { d.name = voice.name }
        do {
            try library.update(d)
            draft = nil
        } catch {
            toasts.show("Couldn't save “\(voice.name)”: \(error.localizedDescription)", tone: .danger)
        }
    }
}

/// Short dates for the inspector's facts, in the user's locale and 12/24-hour setting.
enum VoiceDates {
    /// "Nov 20, 10:40 PM" this year, "Nov 20, 2025" before (the full date and time are in the tooltip).
    static func compact(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return day(date)
    }

    /// "Nov 20, 2026".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}
