import SwiftUI

// MARK: - Slider

/// A fader-style slider: sunken track, tungsten fill, a mixing-desk cap for a thumb, and a
/// monospaced value readout. Optional default-value tick; double-click resets to it.
/// Arrow keys step the value when focused.
///
///     StageSlider("Speed", value: $speed, in: 0.5...2, step: 0.05, defaultValue: 1) { String(format: "%.2f×", $0) }
///     StageSlider("Steps", value: $steps, in: 1...64, defaultValue: 32)          // Int binding
///     StageSlider(value: $mix, in: 0...1)                                         // no title row
struct StageSlider: View {
    private let title: String?
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double?
    private let defaultValue: Double?
    private let format: (Double) -> String

    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var isFocused: Bool
    @State private var isDragging = false
    @State private var isHovered = false

    /// Floating-point binding.
    init<V: BinaryFloatingPoint>(_ title: String? = nil, value: Binding<V>, in range: ClosedRange<V>,
                                 step: V? = nil, defaultValue: V? = nil, format: ((V) -> String)? = nil) {
        self.title = title
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = step.map(Double.init)
        self.defaultValue = defaultValue.map(Double.init)
        if let format {
            self.format = { format(V($0)) }
        } else {
            let span = Double(range.upperBound - range.lowerBound)
            let s = step.map(Double.init) ?? span / 100
            let decimals = s >= 1 ? 0 : (s >= 0.1 ? 1 : (s >= 0.01 ? 2 : 3))
            self.format = { String(format: "%.\(decimals)f", $0) }
        }
    }

    /// Integer binding; `step` defaults to 1.
    init<I: BinaryInteger>(_ title: String? = nil, value: Binding<I>, in range: ClosedRange<I>,
                           step: I = 1, defaultValue: I? = nil, format: ((I) -> String)? = nil) {
        self.title = title
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = I($0.rounded()) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        self.defaultValue = defaultValue.map { Double($0) }
        self.format = { v in format?(I(v.rounded())) ?? String(Int(v.rounded())) }
    }

    private var fraction: Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return (value.wrappedValue - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func set(_ raw: Double) {
        var v = min(max(raw, range.lowerBound), range.upperBound)
        if let step, step > 0 { v = range.lowerBound + ((v - range.lowerBound) / step).rounded() * step }
        v = min(max(v, range.lowerBound), range.upperBound)
        if v != value.wrappedValue { value.wrappedValue = v }
    }

    private func nudge(_ direction: Double) {
        let s = step ?? (range.upperBound - range.lowerBound) / 100
        set(value.wrappedValue + direction * s)
    }

    private func reset() {
        guard let defaultValue else { return }
        withStageAnimation(Theme.Motion.standard) { set(defaultValue) }
    }

    private var isAtDefault: Bool {
        guard let defaultValue else { return true }
        return abs(value.wrappedValue - defaultValue) < (step ?? 1e-9) / 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                if let title { Text(title).textRole(.label, color: .textSecondary) }
                Spacer(minLength: Theme.Space.s)
                Text(format(value.wrappedValue))
                    .textRole(.mono, color: isDragging ? .tungsten : (isAtDefault ? .textSecondary : .textPrimary))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .onTapGesture(count: 2, perform: reset)
                    .help(defaultValue != nil ? "Double-click to reset to \(format(defaultValue!))" : "")
            }
            track
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title ?? "Value")
        .accessibilityValue(format(value.wrappedValue))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(1)
            case .decrement: nudge(-1)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let capWidth: CGFloat = 11
            let usable = max(geo.size.width - capWidth, 1)
            let x = usable * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Color.surfaceSunken)
                    .overlay(Capsule().strokeBorder(Color.hairline, lineWidth: 1))
                    .frame(height: 5)
                Capsule()
                    .fill(LinearGradient(colors: [.tungstenDeep, .tungsten], startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + capWidth / 2, height: 5)
                    .glow(.tungsten, radius: 6, intensity: isDragging ? 0.45 : 0.18)
                if let defaultValue, range.upperBound > range.lowerBound {
                    let f = (defaultValue - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Rectangle()
                        .fill(Color.textTertiary)
                        .frame(width: 1, height: 11)
                        .offset(x: usable * f + capWidth / 2 - 0.5)
                }
                // Fader cap.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: 0xFBF5EC), Color(hex: 0xCFC5B8)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(Color.backdrop.opacity(0.55)).frame(width: 7, height: 1.5))
                    .frame(width: capWidth, height: 18)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .scaleEffect(isDragging ? 1.08 : (isHovered ? 1.04 : 1))
                    .offset(x: x)
                    .overlay {
                        if isFocused {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.tungsten, lineWidth: 1.5)
                                .frame(width: capWidth + 5, height: 23).offset(x: x)
                        }
                    }
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let f = (g.location.x - capWidth / 2) / usable
                        set(range.lowerBound + Double(f) * (range.upperBound - range.lowerBound))
                    }
                    .onEnded { _ in isDragging = false }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded(reset))
            .onHover { isHovered = $0 }
            .stageAnimation(Theme.Motion.quick, value: isDragging)
        }
        .frame(height: 20)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
    }
}

// MARK: - Toggle

/// A slim pilot-light switch. The label sits on the left; the switch lights tungsten when on.
///
///     Toggle("Stream audio", isOn: $stream).toggleStyle(.stage)
struct StageToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        StageToggleBody(configuration: configuration)
    }
}

private struct StageToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let on = configuration.isOn
        Button {
            withStageAnimation(Theme.Motion.standard) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: Theme.Space.m) {
                configuration.label
                    .textRole(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule()
                        .fill(on ? AnyShapeStyle(LinearGradient(colors: [.tungstenDeep, .tungsten], startPoint: .leading, endPoint: .trailing))
                                 : AnyShapeStyle(Color.surfaceSunken))
                        .overlay(Capsule().strokeBorder(on ? Color.white.opacity(0.15) : (isHovered ? .hairlineStrong : .hairline), lineWidth: 1))
                        .glow(.tungsten, radius: 8, intensity: on ? 0.3 : 0)
                    Circle()
                        .fill(on ? Color(hex: 0xFFF6E8) : Color(hex: 0x8A8077))
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 1)
                        .padding(2.5)
                }
                .frame(width: 32, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == StageToggleStyle {
    /// Encore's switch.
    static var stage: StageToggleStyle { .init() }
}

// MARK: - Number field

/// A compact numeric field with − / + steppers and a monospaced, editable value.
///
///     NumberField("Seed", value: $seed, in: 0...99_999)
///     NumberField("Pause", value: $pause, in: 0...5, step: 0.1) { String(format: "%.1f s", $0) }
struct NumberField: View {
    private let title: String?
    private let value: Binding<Double>
    private let range: ClosedRange<Double>
    private let step: Double
    private let format: (Double) -> String
    private let isInteger: Bool

    @State private var draft = ""
    @FocusState private var isEditing: Bool
    @Environment(\.isEnabled) private var isEnabled

    init<V: BinaryFloatingPoint>(_ title: String? = nil, value: Binding<V>, in range: ClosedRange<V>,
                                 step: V = 1, format: ((V) -> String)? = nil) {
        self.title = title
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = V($0) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        let decimals = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2)
        self.format = format.map { f in { f(V($0)) } } ?? { String(format: "%.\(decimals)f", $0) }
        self.isInteger = false
    }

    init<I: BinaryInteger>(_ title: String? = nil, value: Binding<I>, in range: ClosedRange<I>,
                           step: I = 1, format: ((I) -> String)? = nil) {
        self.title = title
        self.value = Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = I($0.rounded()) })
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.step = Double(step)
        self.format = { v in format?(I(v.rounded())) ?? String(Int(v.rounded())) }
        self.isInteger = true
    }

    private func set(_ v: Double) {
        let clamped = min(max(isInteger ? v.rounded() : v, range.lowerBound), range.upperBound)
        value.wrappedValue = clamped
    }

    private func commit() {
        let cleaned = draft.filter { "0123456789.-".contains($0) }
        if let v = Double(cleaned) { set(v) }
        draft = format(value.wrappedValue)
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let title {
                Text(title).textRole(.label, color: .textSecondary)
                Spacer(minLength: Theme.Space.s)
            }
            HStack(spacing: 0) {
                stepButton("minus", label: "Decrease") { set(value.wrappedValue - step) }
                    .disabled(value.wrappedValue <= range.lowerBound)
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.mono(12))
                    .foregroundStyle(.textPrimary)
                    .multilineTextAlignment(.center)
                    .focused($isEditing)
                    .onSubmit(commit)
                    .frame(minWidth: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 4)
                    .accessibilityLabel(title ?? "Value")
                stepButton("plus", label: "Increase") { set(value.wrappedValue + step) }
                    .disabled(value.wrappedValue >= range.upperBound)
            }
            .frame(height: Theme.ControlHeight.regular)
            .surface(.sunken, radius: Theme.Radius.s)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s).strokeBorder(Color.tungsten.opacity(isEditing ? 0.7 : 0), lineWidth: 1))
        }
        .opacity(isEnabled ? 1 : 0.4)
        .onAppear { draft = format(value.wrappedValue) }
        .onChange(of: value.wrappedValue) { _, v in if !isEditing { draft = format(v) } }
        .onChange(of: isEditing) { _, editing in if !editing { commit() } }
    }

    private func stepButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(label, systemImage: symbol, action: action)
            .buttonStyle(.icon)
            .controlSize(.small)
            .padding(.horizontal, 3)
            .buttonRepeatBehavior(.enabled)
    }
}

// MARK: - Segmented control

/// A row of mutually exclusive options on a sunken rail with a sliding raised thumb.
///
///     SegmentedControl(selection: $mode, options: Mode.allCases) { $0.title }
///     SegmentedControl(selection: $fmt, options: ["WAV", "MP3", "FLAC"]) { $0 }
///     SegmentedControl(selection: $kind, options: kinds, count: { counts[$0] }) { $0.title }   // "Speech ⁽¹²⁾"
struct SegmentedControl<Option: Hashable>: View {
    @Binding var selection: Option
    let options: [Option]
    let title: (Option) -> String
    /// A number shown after the title as a `CountBadge`; nil shows none.
    let count: ((Option) -> Int?)?
    @Namespace private var thumb
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    init(selection: Binding<Option>, options: [Option], count: ((Option) -> Int?)? = nil, title: @escaping (Option) -> String) {
        self._selection = selection
        self.options = options
        self.count = count
        self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withStageAnimation(Theme.Motion.standard) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        Text(title(option))
                            .font(.ui(controlSize == .small ? 11 : 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Color.textPrimary : .textSecondary)
                            // The lamp sits under the title (not the count), at the segment's foot.
                            .overlay {
                                if selected {
                                    Capsule().fill(Color.tungsten).frame(width: 14, height: 2)
                                        .glow(.tungsten, radius: 4, intensity: 0.6)
                                        .offset(y: (Theme.ControlHeight.of(controlSize) - 6) / 2 - 3)
                                        .matchedGeometryEffect(id: "lamp", in: thumb)
                                }
                            }
                        if let n = count?(option) {
                            CountBadge(n, isEmphasized: selected)
                        }
                    }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity)
                        .frame(height: Theme.ControlHeight.of(controlSize) - 6)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: Theme.Radius.s - 2, style: .continuous)
                                    .fill(Color.surfaceRaised)
                                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s - 2).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .fixedSize(horizontal: true, vertical: false)
        .surface(.sunken, radius: Theme.Radius.s + 1)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

// MARK: - Menu picker

/// A pop-up picker with Encore chrome. The menu itself is the native one.
///
///     MenuPicker("Language", selection: $lang, options: Language.allCases) { $0.name }
///     MenuPicker(selection: $voice, options: voices) { $0.name }
struct MenuPicker<Option: Hashable>: View {
    let title: String?
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String? = nil, selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            if let title {
                Text(title).textRole(.label, color: .textSecondary)
                Spacer(minLength: Theme.Space.s)
            }
            Menu {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection { Label(label(option), systemImage: "checkmark") } else { Text(label(option)) }
                    }
                }
            } label: {
                HStack(spacing: Theme.Space.s) {
                    Text(label(selection))
                        .font(.ui(12.5, weight: .medium))
                        .foregroundStyle(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.s)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isHovered ? Color.tungsten : .textTertiary)
                }
                .padding(.horizontal, 11)
                .frame(height: Theme.ControlHeight.regular)
                .frame(minWidth: 140)
                .background {
                    RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                        .fill(Color.surfaceRaised)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                            .strokeBorder(isHovered ? Color.hairlineStrong : Color.hairline, lineWidth: 1))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: title != nil, vertical: true)
            .onHover { isHovered = $0 }
        }
        .opacity(isEnabled ? 1 : 0.4)
    }
}
