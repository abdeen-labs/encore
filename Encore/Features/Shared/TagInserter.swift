import EncoreCore
import SwiftUI

/// Three quiet menus that insert tags at the editor's cursor: "Pause" (Encore's pause tag, with lengths),
/// "Voice" (the voice-switch tag, with the voices this model can speak in) and "Sounds" (the model's own expressive
/// tags such as Laugh or Sigh; hidden when it has none). They always fit: no scrolling, no fade, so a caller
/// needs no mask. The row is leading-aligned and takes the width it is given.
///
///     TagInserter(manifest: manifest) { editor.insert($0) }
///     TagInserter(manifest: manifest, includesVoiceSwitch: false) { editor.insert($0) }
struct TagInserter: View {
    let manifest: ModelManifest
    var includesPause: Bool = true
    var includesVoiceSwitch: Bool = true
    let insert: (String) -> Void

    @Environment(VoiceLibrary.self) private var library

    init(manifest: ModelManifest, includesPause: Bool = true, includesVoiceSwitch: Bool = true, insert: @escaping (String) -> Void) {
        self.manifest = manifest
        self.includesPause = includesPause
        self.includesVoiceSwitch = includesVoiceSwitch
        self.insert = insert
    }

    var body: some View {
        HStack(spacing: 6) {
            if includesPause {
                Menu {
                    ForEach([0.25, 0.5, 1, 2, 3], id: \.self) { s in
                        Button(Self.pauseLabel(s)) { insert(Self.pauseTag(s)) }
                    }
                } label: { InserterLabel(title: "Pause", symbol: "pause") }
                    .inserterMenu()
                    .help("Insert real silence: [pause 1s]")
            }
            if includesVoiceSwitch {
                Menu {
                    let cast = castable
                    if cast.isEmpty {
                        Text("No other voices for \(manifest.name)")
                    }
                    ForEach(cast, id: \.self) { name in
                        Button(name) { insert("[voice: \(name)]") }
                    }
                    Divider()
                    Button("Back to the main voice") { insert("[voice: default]") }
                } label: { InserterLabel(title: "Voice", symbol: "person.2", symbolColor: .lilacInk) }
                    .inserterMenu()
                    .help("Switch voice from here on: [voice: Name]")
            }
            if !manifest.expressiveTags.isEmpty {
                Menu {
                    ForEach(manifest.expressiveTags) { tag in
                        Button(tag.label) { insert(Self.insertable(tag.tag)) }
                    }
                } label: { InserterLabel(title: "Sounds", symbol: "face.smiling") }
                    .inserterMenu()
                    .help("Insert a sound \(manifest.name) can make, like \(manifest.expressiveTags[0].tag)")
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Names a `[voice:]` tag can use with this model: library voices when it clones, plus its presets.
    private var castable: [String] {
        var names: [String] = []
        if manifest.capabilities.cloning { names += library.voices.map(\.name) }
        names += manifest.presetVoices.map(\.name)
        return names
    }

    static func pauseTag(_ s: Double) -> String {
        s < 1 ? "[pause \(Int(s * 1000))ms]" : "[pause \(s == s.rounded() ? String(Int(s)) : String(s))s]"
    }

    static func pauseLabel(_ s: Double) -> String {
        s < 1 ? "\(Int(s * 1000)) ms" : (s == s.rounded() ? "\(Int(s)) s" : "\(s) s")
    }

    /// Family tags like `[S*]` insert their first member.
    static func insertable(_ tag: String) -> String { tag.replacingOccurrences(of: "*", with: "1") }
}

private extension View {
    func inserterMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A neutral pill: glyph, title, chevron.
private struct InserterLabel: View {
    let title: String
    let symbol: String
    var symbolColor: Color = .textTertiary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(symbolColor)
            Text(title).textRole(.label, color: isHovered ? .textPrimary : .textSecondary).lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(Color.textPrimary.opacity(isHovered ? 0.06 : 0)))
        .overlay(Capsule().inset(by: 0.5).stroke(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isHovered)
    }
}
