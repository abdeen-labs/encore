import EncoreCore
import SwiftUI

/// A strip of chips that insert tags at the editor's cursor: Encore's pause tag (with lengths), the voice-switch
/// tag (with the voices this model can speak in), then the model's own expressive tags. Each chip is colored
/// like the tag it inserts in `TaggedScriptEditor`.
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
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if includesPause {
                    Menu {
                        ForEach([0.25, 0.5, 1, 2, 3], id: \.self) { s in
                            Button(Self.pauseLabel(s)) { insert(Self.pauseTag(s)) }
                        }
                    } label: { TagChip(title: "Pause", symbol: "pause", kind: .pause, hasMenu: true) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
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
                    } label: { TagChip(title: "Voice", symbol: "person.2", kind: .voice, hasMenu: true) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Switch voice from here on: [voice: Name]")
                }
                if !manifest.expressiveTags.isEmpty {
                    Rectangle().fill(Color.hairline).frame(width: 1, height: 16).padding(.horizontal, 2)
                    ForEach(manifest.expressiveTags) { tag in
                        Button { insert(Self.insertable(tag.tag)) } label: {
                            TagChip(title: tag.label, symbol: nil, kind: .expressive, hasMenu: false)
                        }
                        .buttonStyle(.plain)
                        .help("Insert \(tag.tag)")
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
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

private struct TagChip: View {
    let title: String
    let symbol: String?
    let kind: ScriptTagKind
    let hasMenu: Bool
    @State private var isHovered = false

    var body: some View {
        let color = ScriptTagStyle.color(kind)
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .bold)) }
            Text(title).font(.ui(11.5, weight: .medium)).lineLimit(1)
            if hasMenu { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.7) }
        }
        .foregroundStyle(color.opacity(isHovered ? 1 : 0.88))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(isHovered ? 0.16 : 0.08)))
        .overlay(Capsule().strokeBorder(color.opacity(isHovered ? 0.5 : 0.24), lineWidth: 1))
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isHovered)
    }
}
