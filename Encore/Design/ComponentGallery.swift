#if DEBUG
import SwiftUI
import UniformTypeIdentifiers

/// Every component in its states. DEBUG only; reachable from the rail and ⇧⌘G, and rendered
/// by `--snapshot` as Gallery.png / Gallery-full.png.
struct ComponentGallery: View {
    @Environment(ToastCenter.self) private var toasts

    @State private var speed = 1.15
    @State private var steps = 40
    @State private var mix = 0.5
    @State private var stream = true
    @State private var normalize = false
    @State private var seed = 4207
    @State private var pause = 0.4
    @State private var mode = "Balanced"
    @State private var format = "WAV"
    @State private var language = "English"
    @State private var name = "Narrator — Warm"
    @State private var empty = ""
    @State private var query = "captain"
    @State private var script = "The house lights dim. A single spot finds the center of the stage, and the voice begins — low, unhurried, certain of its audience.\n\nThis is the line we will perform."
    @State private var warm = true
    @State private var bright = false
    @State private var tags = ["narration", "calm", "en-GB"]
    @State private var showSheet = false
    @State private var advancedOpen = true

    var body: some View {
        ScreenScaffold("Gallery", subtitle: "Every component, every state.") {
            group("Type") { typeSamples }
            group("Color") { swatches }
            group("Buttons") { buttons }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Card {
                    SectionHeader("Sliders", subtitle: "Double-click the value or track to reset")
                    StageSlider("Speed", value: $speed, in: 0.5...2, step: 0.05, defaultValue: 1) { String(format: "%.2f×", $0) }
                    StageSlider("Diffusion steps", value: $steps, in: 1...64, defaultValue: 32)
                    StageSlider(value: $mix, in: 0...1)
                    StageSlider("Disabled", value: .constant(0.3), in: 0...1).disabled(true)
                }
                Card {
                    SectionHeader("Switches & numbers")
                    Toggle("Stream while generating", isOn: $stream).toggleStyle(.stage)
                    Toggle("Normalize loudness", isOn: $normalize).toggleStyle(.stage)
                    Toggle("Disabled", isOn: .constant(true)).toggleStyle(.stage).disabled(true)
                    NumberField("Seed", value: $seed, in: 0...99_999)
                    NumberField("Pause between lines", value: $pause, in: 0...5, step: 0.1) { String(format: "%.1f s", $0) }
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Card {
                    SectionHeader("Choosers")
                    SegmentedControl(selection: $mode, options: ["Fast", "Balanced", "Quality"]) { $0 }
                    SegmentedControl(selection: $format, options: ["WAV", "MP3", "FLAC", "M4A"]) { $0 }
                        .controlSize(.small)
                    SegmentedControl(selection: $mode, options: ["Fast", "Balanced", "Quality"], count: { [12, 3, 0][["Fast", "Balanced", "Quality"].firstIndex(of: $0)!] }) { $0 }
                        .controlSize(.small)
                    MenuPicker("Language", selection: $language, options: ["English", "French", "Japanese", "Spanish"]) { $0 }
                    MenuPicker(selection: $language, options: ["English", "French", "Japanese", "Spanish"]) { $0 }
                }
                Card {
                    SectionHeader("Text")
                    StageTextField("Voice name", text: $name, title: "Name")
                    StageTextField("https://…", text: $empty, symbol: "link")
                    SearchField(text: $query, prompt: "Search voices")
                    SearchField(text: $empty, prompt: "Search history")
                }
            }
            Card {
                SectionHeader("Script editor", subtitle: "For long scripts")
                ScriptEditor(text: $script, minHeight: 120)
                ScriptEditor(text: $empty, placeholder: "Type the lines to perform…", minHeight: 70)
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Card {
                    SectionHeader("Chips")
                    HStack(spacing: 6) {
                        Chip("English")
                        Chip("Cloned", symbol: "mic", tone: .accent)
                        Chip("Ready", tone: .success)
                        Chip("Large", tone: .warning)
                    }
                    HStack(spacing: 6) {
                        CountBadge(7)
                        CountBadge(42, isEmphasized: true)
                        KeycapBadge("1")
                        KeycapBadge("⇧G")
                    }
                    HStack(spacing: 6) {
                        Chip("Warm", isSelected: $warm)
                        Chip("Bright", isSelected: $bright)
                        ForEach(tags, id: \.self) { tag in
                            Chip(tag, onRemove: { tags.removeAll { $0 == tag } })
                        }
                    }
                }
                Card {
                    SectionHeader("Status")
                    HStack(spacing: Theme.Space.m) {
                        StatusBadge("Idle")
                        StatusBadge("Working", tone: .accent, pulsing: true)
                        StatusBadge("On this Mac", tone: .success)
                        StatusBadge("Low disk", tone: .warning)
                        StatusBadge("Recording", tone: .danger, pulsing: true)
                    }
                    HStack(spacing: Theme.Space.l) {
                        ActivityIndicator()
                        ActivityIndicator(tone: .danger, size: 22)
                        ProgressBar(value: 0.62)
                    }
                    ProgressBar(value: nil, tone: .success)
                }
            }
            group("Banners") {
                Banner(.neutral, title: "Models run on this Mac", message: "Nothing you type or record leaves the device.")
                Banner(.warning, title: "Model not downloaded", message: "Soprano is needed to perform in Studio.") {
                    Button("Download") {}.buttonStyle(.secondary).controlSize(.small)
                }
                Banner(.danger, title: "Generation failed", message: "The model ran out of memory. Try a shorter script.", onDismiss: {})
                Banner(.success, title: "Voice cloned", message: "“Captain” is in your cast.")
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                Card {
                    SectionHeader("Take 03", subtitle: "Details, separated by a hairline")
                    Waveform(samples: Waveform.placeholder(count: 110), progress: 0.38)
                        .frame(height: 44)
                    Hairline()
                    KeyValueRow("Voice", value: "Captain")
                    KeyValueRow("Duration", value: "0:42.18")
                    KeyValueRow("Sample rate", value: "24 kHz")
                    KeyValueRow("Model") { StatusBadge("Loaded", tone: .success) }
                }
                Card {
                    SectionHeader("Disclosure & overlays")
                    AdvancedDisclosure(isExpanded: $advancedOpen) {
                        StageSlider("Temperature", value: .constant(0.7), in: 0...2, step: 0.05, defaultValue: 0.7)
                        Toggle("Deterministic", isOn: .constant(false)).toggleStyle(.stage)
                    }
                    AdvancedDisclosure("Sampling") { Text("Hidden") }
                    HStack {
                        Button("Show toast") { toasts.show("Saved to History", tone: .success) }
                            .buttonStyle(.secondary)
                        Button("Open sheet") { showSheet = true }
                            .buttonStyle(.secondary)
                    }
                    ToastView(toast: Toast(message: "Saved to History", tone: .success))
                }
            }
            group("Audio") { AudioGallerySection() }
            group("Drop zone") {
                DropZone(title: "Drop a reference clip", message: "WAV, MP3 or M4A · 5–30 seconds of clean speech",
                         allowedTypes: [.audio]) { _ in }
            }
            group("Empty states") {
                HStack(alignment: .top, spacing: Theme.Space.l) {
                    Card(.card, padding: 0) {
                        EmptyState(symbol: "waveform", title: "No takes yet", message: "Write a line and press Perform. Every take lands here.") {
                            Button("Open Studio") {}.buttonStyle(.primary)
                            Button("Import audio") {}.buttonStyle(.ghost)
                        }
                    }
                    Card(.card, padding: 0) {
                        EmptyState(symbol: "magnifyingglass", title: "Nothing matches",
                                   message: "Try another word, or clear the filters.", style: .plain) {
                            Button("Clear filters") {}.buttonStyle(.secondary).controlSize(.small)
                        }
                    }
                }
            }
            group("Sheet") {
                SheetContainer(title: "Export take", subtitle: "Choose a format and destination") {
                    SegmentedControl(selection: $format, options: ["WAV", "MP3", "FLAC"]) { $0 }
                    Toggle("Include transcript", isOn: $stream).toggleStyle(.stage)
                } actions: {
                    Button("Cancel") {}.buttonStyle(.ghost)
                    Button("Export") {}.buttonStyle(.primary)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l).strokeBorder(Color.hairline))
            }
        } actions: {
            Button("Ghost") {}.buttonStyle(.ghost)
            Button("Perform", systemImage: "play.fill") {}.buttonStyle(.primary)
        }
        .stageSheet(isPresented: $showSheet) {
            SheetContainer(title: "Export take", subtitle: "Choose a format and destination") {
                SegmentedControl(selection: $format, options: ["WAV", "MP3", "FLAC"]) { $0 }
            } actions: {
                Button("Cancel") { showSheet = false }.buttonStyle(.ghost)
                Button("Export") { showSheet = false }.buttonStyle(.primary)
            }
        }
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title).textRole(.eyebrow)
            content()
        }
        .padding(.top, Theme.Space.s)
    }

    private var typeSamples: some View {
        Card {
            Text("Marquee — Encore").textRole(.marquee)
            Text("Title — The stage is set").textRole(.title)
            Text("Heading — Captain").textRole(.heading)
            Text("Section — Variants").textRole(.section)
            Text("Headline — Captain, take three").textRole(.headline)
            Text("Body — Write the lines, cast a voice, and press Perform. Everything runs on this Mac.").textRole(.body)
            Text("Label — Speaking rate").textRole(.label)
            Text("Caption — Applies to new takes only.").textRole(.caption)
            Text("Eyebrow — Advanced").textRole(.eyebrow)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xl) {
                Text("0:12.4").textRole(.readout)
                Text("Mono 00:42.180  1.15×  24 kHz").textRole(.mono)
                Text("monoSmall 0:42").textRole(.monoSmall)
            }
            Hairline()
            HStack(spacing: Theme.Space.m) {
                Text("Hairline").textRole(.caption)
                Hairline(.vertical).frame(height: 14)
                Text("and its vertical variant").textRole(.caption)
            }
        }
    }

    private var swatches: some View {
        let colors: [(String, Color)] = [
            ("backdrop", .backdrop), ("rail", .rail), ("surface", .surface), ("raised", .surfaceRaised),
            ("sunken", .surfaceSunken), ("text", .textPrimary), ("text 2", .textSecondary), ("text 3", .textTertiary),
            ("tungsten", .tungsten), ("velvet", .velvet), ("velvet text", .velvetText), ("mint", .mint),
            ("footlight", .footlight), ("gel", .gel),
        ]
        return HStack(spacing: Theme.Space.s) {
            ForEach(colors, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: 6) {
                    RoundedRectangle(cornerRadius: Theme.Radius.s)
                        .fill(color)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Color.hairline))
                        .frame(height: 38)
                    Text(name).textRole(.monoSmall, color: .textTertiary).lineLimit(1)
                }
            }
        }
    }

    private var buttons: some View {
        Card {
            ForEach([ControlSize.small, .regular, .large], id: \.self) { size in
                HStack(spacing: Theme.Space.s) {
                    Button("Perform", systemImage: "play.fill") {}.buttonStyle(.primary)
                    Button("Audition") {}.buttonStyle(.secondary)
                    Button("Cancel") {}.buttonStyle(.ghost)
                    Button("Delete take", systemImage: "trash") {}.buttonStyle(.destructive)
                    Spacer()
                    Button("Shuffle", systemImage: "shuffle") {}.buttonStyle(.icon)
                    Button("More", systemImage: "ellipsis") {}.buttonStyle(.icon)
                    Button("Play", systemImage: "play.fill") {}.buttonStyle(.play(isPlaying: false))
                    Button("Pause", systemImage: "pause.fill") {}.buttonStyle(.play(isPlaying: true))
                }
                .controlSize(size)
            }
            HStack(spacing: Theme.Space.s) {
                Button("Perform", systemImage: "play.fill") {}.buttonStyle(.primary)
                Button("Audition") {}.buttonStyle(.secondary)
                Button("Delete") {}.buttonStyle(.destructive)
                Button("Play", systemImage: "play.fill") {}.buttonStyle(.play(isPlaying: false))
                Text("disabled").textRole(.caption)
            }
            .disabled(true)
        }
    }
}
#endif
