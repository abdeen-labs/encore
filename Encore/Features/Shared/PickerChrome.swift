import SwiftUI

/// The trigger every shared picker uses: an eyebrow label over a value line, on a raised plate. It stays unlit
/// while its panel is open (a stronger edge says so); the light belongs to the selected row inside.
///
///     PickerPlate(label: "Voice", symbol: "person.wave.2", value: "Heart", detail: "Model voice", isOpen: open) { open.toggle() }
struct PickerPlate<Badge: View>: View {
    let label: String
    var symbol: String
    let value: String
    var detail: String?
    var isOpen: Bool
    var action: () -> Void
    @ViewBuilder var badge: Badge
    /// One line, no label or glyph, 30 pt tall: for a picker that sits inside a row which already says what it is.
    var isCompact = false

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    /// The one-line form (see `isCompact`).
    func compact(_ on: Bool = true) -> PickerPlate {
        var copy = self
        copy.isCompact = on
        return copy
    }

    init(label: String, symbol: String, value: String, detail: String? = nil, isOpen: Bool,
         action: @escaping () -> Void, @ViewBuilder badge: () -> Badge) {
        self.label = label; self.symbol = symbol; self.value = value; self.detail = detail
        self.isOpen = isOpen; self.action = action; self.badge = badge()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                if !isCompact {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isOpen || isHovered ? Color.textSecondary : .textTertiary)
                        .frame(width: 16)
                }
                VStack(alignment: .leading, spacing: 1) {
                    if !isCompact { Text(label).textRole(.eyebrow) }
                    HStack(spacing: 5) {
                        Text(value).textRole(isCompact ? .label : .headline, color: .textPrimary).lineLimit(1)
                            .layoutPriority(1)
                        if let detail {
                            Text(detail).textRole(.caption, color: .textTertiary).lineLimit(1)
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 2)
                badge
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(isOpen ? Color.textSecondary : .textTertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 10)
            .frame(height: isCompact ? Theme.ControlHeight.regular : 42)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                shape.fill(Color.surfaceRaised)
                    .brightness(isHovered ? 0.02 : 0)
                    .overlay(shape.strokeBorder(isOpen || isHovered ? Color.hairlineStrong : .hairline, lineWidth: 1))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isOpen)
        .accessibilityLabel("\(label): \(value)")
    }
}

extension PickerPlate where Badge == EmptyView {
    init(label: String, symbol: String, value: String, detail: String? = nil, isOpen: Bool, action: @escaping () -> Void) {
        self.init(label: label, symbol: symbol, value: value, detail: detail, isOpen: isOpen, action: action) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// Snapshots: draw picker panels in place (under their trigger) instead of in a popover window,
    /// so they show up in the captured image.
    @Entry var inlinePickerPanels: Bool = false
    /// Snapshots: the picker ("model", "voice") that starts open.
    @Entry var snapshotOpenPicker: String? = nil
}

extension View {
    /// Presents `panel` as a popover under the view, or (snapshots) drawn in place over the content below.
    func pickerPanel<Panel: View>(isPresented: Binding<Bool>, width: CGFloat, @ViewBuilder panel: @escaping () -> Panel) -> some View {
        modifier(PickerPanelModifier(isPresented: isPresented, width: width, panel: panel))
    }
}

private struct PickerPanelModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let width: CGFloat
    let panel: () -> Panel
    @Environment(\.inlinePickerPanels) private var inline

    func body(content: Content) -> some View {
        if inline {
            content
                .overlay(alignment: .topLeading) {
                    if isPresented {
                        panelBody
                            .background(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).fill(Color.surfaceRaised))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                            .elevation()
                            .offset(y: 48)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
                .zIndex(isPresented ? 10 : 0)
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: .bottom) {
                panelBody
                    .background(Color.surfaceRaised)
                    .preferredColorScheme(.light)
            }
        }
    }

    private var panelBody: some View {
        panel().frame(width: width)
    }
}

/// A row in a picker panel: selectable, with a lit edge when selected (the one lit thing in the list).
struct PickerRow<Content: View>: View {
    var isSelected: Bool
    var isEnabled: Bool = true
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                content
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
                shape.fill(Color.textPrimary.opacity(isSelected ? 0.06 : (isHovered && isEnabled ? 0.04 : 0)))
                    .overlay(alignment: .leading) {
                        if isSelected {
                            Capsule().fill(Color.tangerine).frame(width: 2.5).padding(.vertical, 6)
                        }
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small caps heading inside a picker panel.
struct PanelHeading: View {
    let title: String
    var count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).textRole(.eyebrow)
            if let count { Text("\(count)").textRole(.monoSmall, color: .textTertiary) }
            Hairline()
        }
        .padding(.horizontal, 10)
        .padding(.top, Theme.Space.s)
        .padding(.bottom, 2)
    }
}
