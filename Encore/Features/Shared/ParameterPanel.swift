import EncoreCore
import SwiftUI

/// Every generation control a model exposes, rendered from `ModelManifest.parameters`: basic ones inline,
/// the rest in an "Advanced" disclosure. Each type gets the right control (fader with default tick for numbers,
/// switch, segmented/menu choice, text, seed with dice); help text sits behind a small "?" on each label; a quiet
/// dot marks values that differ from the default, and "N changed from default · Reset" (shown only when N > 0)
/// puts them all back.
///
///     ParameterPanel(manifest: manifest, values: $parameters)
///     ParameterPanel(manifest: manifest, values: $parameters, advancedExpanded: $showAdvanced)
///
/// - `values` is sparse: a key is present only when it differs from the manifest default. Setting a control back
///   to its default removes the key. Send it as `request.parameters` as is (the service fills in defaults).
struct ParameterPanel: View {
    let manifest: ModelManifest
    @Binding var values: ParamValues
    var advancedExpanded: Binding<Bool>?
    /// Show the "Reset" link in the panel's own header row.
    var showsHeader: Bool = true

    init(manifest: ModelManifest, values: Binding<ParamValues>, advancedExpanded: Binding<Bool>? = nil, showsHeader: Bool = true) {
        self.manifest = manifest
        self._values = values
        self.advancedExpanded = advancedExpanded
        self.showsHeader = showsHeader
    }

    private var basic: [ParameterSpec] { manifest.parameters.filter { $0.tier == .basic } }
    private var advanced: [ParameterSpec] { manifest.parameters.filter { $0.tier == .advanced } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if manifest.parameters.isEmpty {
                Text("\(manifest.name) has no generation settings.").textRole(.caption, color: .textTertiary)
            }
            if showsHeader, !manifest.parameters.isEmpty {
                ParameterResetRow(manifest: manifest, values: $values)
            }
            ForEach(basic) { ParameterControl(spec: $0, values: $values) }
            if !advanced.isEmpty {
                let changed = ParameterValues.changedCount(advanced, values)
                let title = changed > 0 ? "Advanced · \(changed)" : "Advanced"
                if let advancedExpanded {
                    AdvancedDisclosure(title, isExpanded: advancedExpanded) { advancedControls }
                } else {
                    AdvancedDisclosure(title) { advancedControls }
                }
            }
        }
    }

    @ViewBuilder private var advancedControls: some View {
        ForEach(advanced) { ParameterControl(spec: $0, values: $values) }
    }
}

/// "2 changed from default · Reset" for a parameter set; draws nothing while every value is the default.
/// Part of `ParameterPanel`; usable in a custom header.
struct ParameterResetRow: View {
    let manifest: ModelManifest
    @Binding var values: ParamValues

    var body: some View {
        let changed = ParameterValues.changedCount(manifest.parameters, values)
        if changed > 0 {
            HStack(spacing: Theme.Space.s) {
                ChangedDot(changed: true)
                Text("\(changed) changed from default").textRole(.caption)
                Spacer()
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    withStageAnimation { values = [:] }
                }
                .buttonStyle(.ghost)
                .controlSize(.small)
                .help("Put every setting back to \(manifest.name)'s default")
            }
        }
    }
}

/// The "changed from default" marker: information, not light. A neutral dot, no glow.
private struct ChangedDot: View {
    var changed: Bool
    var body: some View {
        Circle()
            .fill(changed ? Color.textSecondary : .clear)
            .frame(width: 5, height: 5)
            .accessibilityHidden(true)
    }
}

/// Reading and writing sparse parameter values against their specs.
enum ParameterValues {
    static func value(_ spec: ParameterSpec, in values: ParamValues) -> ParamValue? { values[spec.key] ?? spec.defaultValue }

    static func isChanged(_ spec: ParameterSpec, _ values: ParamValues) -> Bool {
        guard let v = values[spec.key] else { return false }
        return !same(v, spec.defaultValue)
    }

    static func changedCount(_ specs: [ParameterSpec], _ values: ParamValues) -> Int {
        specs.filter { isChanged($0, values) }.count
    }

    /// Sets a value, dropping the key when it equals the default.
    static func set(_ value: ParamValue?, for spec: ParameterSpec, in values: inout ParamValues) {
        if let value, !same(value, spec.defaultValue) { values[spec.key] = value } else { values[spec.key] = nil }
    }

    /// Keeps only keys the manifest knows, with values that differ from their defaults.
    static func normalized(_ values: ParamValues, for manifest: ModelManifest) -> ParamValues {
        var out: ParamValues = [:]
        for spec in manifest.parameters { if let v = values[spec.key] { set(v, for: spec, in: &out) } }
        return out
    }

    static func same(_ a: ParamValue?, _ b: ParamValue?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?):
            if let x = a.doubleValue, let y = b.doubleValue { return abs(x - y) < 1e-9 }
            return a == b
        default: return false
        }
    }
}

/// One parameter's control, chosen by its type.
struct ParameterControl: View {
    let spec: ParameterSpec
    @Binding var values: ParamValues

    private var changed: Bool { ParameterValues.isChanged(spec, values) }

    var body: some View {
        switch spec.type {
        case .float, .int: numeric
        case .bool:
            Toggle(isOn: Binding(get: { ParameterValues.value(spec, in: values)?.boolValue ?? false },
                                 set: { ParameterValues.set(.bool($0), for: spec, in: &values) })) {
                label
            }
            .toggleStyle(.stage)
        case .choice: choice
        case .text:
            VStack(alignment: .leading, spacing: 6) {
                label
                StageTextField(spec.help ?? spec.label, text: Binding(
                    get: { ParameterValues.value(spec, in: values)?.stringValue ?? "" },
                    set: { ParameterValues.set($0.isEmpty ? nil : .string($0), for: spec, in: &values) }))
            }
        case .seed:
            SeedControl(spec: spec, values: $values) { label }
        }
    }

    private var label: some View {
        ParameterLabel(spec: spec, changed: changed)
    }

    // MARK: Numbers

    private var range: ClosedRange<Double> {
        let lo = spec.min ?? 0
        let hi = max(spec.max ?? 1, lo + (spec.step ?? 0.01))
        return lo...hi
    }

    @ViewBuilder private var numeric: some View {
        let def = spec.defaultValue?.doubleValue
        ZStack(alignment: .topLeading) {
            if spec.type == .int {
                StageSlider(value: Binding<Int>(
                    get: { ParameterValues.value(spec, in: values)?.intValue ?? Int(range.lowerBound) },
                    set: { ParameterValues.set(.int($0), for: spec, in: &values) }),
                            in: Int(range.lowerBound)...Int(range.upperBound), step: max(1, Int(spec.step ?? 1)),
                            defaultValue: def.map { Int($0) }, format: { formatted(Double($0)) })
            } else {
                StageSlider(value: Binding<Double>(
                    get: { ParameterValues.value(spec, in: values)?.doubleValue ?? range.lowerBound },
                    set: { ParameterValues.set(.double(($0 * 1e6).rounded() / 1e6), for: spec, in: &values) }),
                            in: range, step: spec.step, defaultValue: def, format: formatted)
            }
            label
        }
    }

    private func formatted(_ v: Double) -> String {
        let step = spec.step ?? (spec.type == .int ? 1 : 0.01)
        let decimals = spec.type == .int || step >= 1 ? 0 : (step >= 0.1 ? 1 : (step >= 0.01 ? 2 : 3))
        let number = String(format: "%.\(decimals)f", v)
        guard let unit = spec.unit, !unit.isEmpty else { return number }
        return unit == "×" ? number + "×" : "\(number) \(unit)"
    }

    // MARK: Choice

    @ViewBuilder private var choice: some View {
        let options = spec.options ?? []
        let current = ParameterValues.value(spec, in: values)?.stringValue ?? options.first?.value ?? ""
        let binding = Binding<String>(get: { current }, set: { ParameterValues.set(.string($0), for: spec, in: &values) })
        let label: (String) -> String = { v in options.first { $0.value == v }?.label ?? v }
        if options.count <= 3, options.allSatisfy({ $0.label.count <= 12 }) {
            HStack {
                self.label
                Spacer(minLength: Theme.Space.s)
                SegmentedControl(selection: binding, options: options.map(\.value), title: label).controlSize(.small)
            }
        } else {
            HStack {
                self.label
                Spacer(minLength: Theme.Space.s)
                MenuPicker(selection: binding, options: options.map(\.value), label: label)
            }
        }
    }
}

/// A parameter's label: changed dot, name, and a "?" that shows the help text.
struct ParameterLabel: View {
    let spec: ParameterSpec
    var changed: Bool
    @State private var showsHelp = false

    var body: some View {
        HStack(spacing: 5) {
            ChangedDot(changed: changed)
            Text(spec.label).textRole(.label, color: changed ? .textPrimary : .textSecondary)
            if let help = spec.help, !help.isEmpty {
                Button("About \(spec.label)", systemImage: "questionmark.circle") { showsHelp.toggle() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(showsHelp ? Color.textPrimary : .textTertiary)
                    .help(help)
                    .popover(isPresented: $showsHelp, arrowEdge: .top) {
                        Text(help).textRole(.caption, color: .textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 240, alignment: .leading)
                            .padding(Theme.Space.m)
                            .background(Color.surfaceRaised)
                            .preferredColorScheme(.light)
                    }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(changed ? "Changed" : "Default")
    }
}

/// Seed: "Random" until fixed. The dice picks a new fixed seed; the field edits it; × goes back to random.
struct SeedControl<Label: View>: View {
    let spec: ParameterSpec
    @Binding var values: ParamValues
    @ViewBuilder var label: Label
    @State private var draft = ""
    @FocusState private var editing: Bool

    private var seed: Int? { values[spec.key]?.intValue ?? spec.defaultValue?.intValue }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            label
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: 0) {
                TextField("", text: $draft, prompt: Text("Random").foregroundStyle(Color.textTertiary))
                    .textFieldStyle(.plain)
                    .textRole(.mono)
                    .multilineTextAlignment(.trailing)
                    .focused($editing)
                    .onSubmit(commit)
                    .frame(width: 78)
                    .padding(.horizontal, 8)
                    .accessibilityLabel(spec.label)
                if seed != nil {
                    Button("Use a random seed", systemImage: "xmark") { set(nil) }
                        .buttonStyle(.icon).controlSize(.small)
                        .help("Random each time")
                }
                Button("Pick a seed", systemImage: "dice") { set(Int.random(in: 0...999_999)) }
                    .buttonStyle(.icon).controlSize(.small)
                    .help("Fix a new random seed, so the take can be reproduced")
                    .padding(.trailing, 2)
            }
            .frame(height: Theme.ControlHeight.regular)
            .surface(.sunken, radius: Theme.Radius.s)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Color.tangerine.opacity(editing ? 0.7 : 0), lineWidth: 1))
        }
        .onAppear { draft = seed.map(String.init) ?? "" }
        .onChange(of: seed) { _, s in if !editing { draft = s.map(String.init) ?? "" } }
        .onChange(of: editing) { _, e in if !e { commit() } }
    }

    private func commit() {
        let digits = draft.filter(\.isNumber)
        set(digits.isEmpty ? nil : Int(digits.prefix(9)))
    }

    private func set(_ s: Int?) {
        ParameterValues.set(s.map { .int($0) }, for: spec, in: &values)
        draft = s.map(String.init) ?? ""
    }
}

// MARK: - Post-processing

/// Silence removal, loudness normalization (with target) and, when given, auto-chunking of long text.
///
///     PostProcessingControls(options: $post)
///     PostProcessingControls(options: $post, autoChunk: $autoChunk, chunkLimit: manifest.maxChunkCharacters)
struct PostProcessingControls: View {
    @Binding var options: PostProcessingOptions
    var autoChunk: Binding<Bool>?
    /// The model's chunk size, for the auto-chunk caption.
    var chunkLimit: Int?

    init(options: Binding<PostProcessingOptions>, autoChunk: Binding<Bool>? = nil, chunkLimit: Int? = nil) {
        self._options = options
        self.autoChunk = autoChunk
        self.chunkLimit = chunkLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Toggle(isOn: $options.removeSilence) { caption("Tighten silences", "Trim the ends and shorten long gaps") }
                .toggleStyle(.stage)
            if options.removeSilence {
                StageSlider("Longest gap", value: $options.maxSilenceSeconds, in: 0.1...2, step: 0.05,
                            defaultValue: PostProcessingOptions().maxSilenceSeconds) { String(format: "%.2f s", $0) }
                    .padding(.leading, Theme.Space.m)
                    .transition(.opacity)
            }
            Toggle(isOn: $options.normalizeLoudness) { caption("Normalize loudness", "Even level across takes") }
                .toggleStyle(.stage)
            if options.normalizeLoudness {
                StageSlider("Target", value: $options.targetLUFS, in: -30 ... -8, step: 0.5,
                            defaultValue: PostProcessingOptions().targetLUFS) { String(format: "%.1f LUFS", $0) }
                    .padding(.leading, Theme.Space.m)
                    .transition(.opacity)
            }
            if let autoChunk {
                Toggle(isOn: autoChunk) {
                    caption("Split long text", chunkLimit.map { "Chunks of up to \($0) characters, at sentence ends" }
                            ?? "At sentence ends, to fit the model")
                }
                .toggleStyle(.stage)
            }
        }
        .stageAnimation(Theme.Motion.standard, value: options)
    }

    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).textRole(.body)
            Text(detail).textRole(.caption, color: .textTertiary)
        }
    }
}
