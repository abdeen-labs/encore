import SwiftUI
import UniformTypeIdentifiers

// MARK: - Empty state

/// How an `EmptyState` is staged.
enum EmptyStateStyle: Sendable, Hashable {
    /// A symbol in a cone and pool of light, a display-serif title. For a screen's main empty state only
    /// (the spotlight is the one full-screen decoration).
    case spotlight
    /// No cone or pool: a smaller symbol in secondary text, a `section` title, tighter padding. For panels
    /// and secondary empties.
    case plain
}

/// An empty stage: a symbol, a title, a line of copy and optional actions. `.spotlight` (the default) stands
/// the symbol in a pool of light; `.plain` is the quiet version for panels.
///
///     EmptyState(symbol: "waveform", title: "No takes yet", message: "Write a line and press Perform.")
///     EmptyState(symbol: "person.wave.2", title: "No voices", message: "…") {
///         Button("Clone a voice") { router.go(.clone) }.buttonStyle(.primary)
///     }
///     EmptyState(symbol: "magnifyingglass", title: "Nothing matches", style: .plain)
///     EmptyState(symbol: "waveform", title: "No takes") { … }.emptyStateStyle(.plain)
struct EmptyState<Actions: View>: View {
    typealias Style = EmptyStateStyle

    let symbol: String
    let title: String
    var message: String?
    var style: EmptyStateStyle = .spotlight
    @ViewBuilder var actions: Actions

    init(symbol: String, title: String, message: String? = nil, style: EmptyStateStyle = .spotlight,
         @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.style = style
        self.actions = actions()
    }

    /// The same empty state, staged in `newStyle`.
    func emptyStateStyle(_ newStyle: EmptyStateStyle) -> EmptyState {
        var copy = self
        copy.style = newStyle
        return copy
    }

    var body: some View {
        switch style {
        case .spotlight: spotlightBody
        case .plain: plainBody
        }
    }

    private var plainBody: some View {
        VStack(spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.textSecondary)
            VStack(spacing: Theme.Space.xs) {
                Text(title).textRole(.section).multilineTextAlignment(.center)
                if let message {
                    Text(message).textRole(.body, color: .textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
            }
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.top, Theme.Space.xxs)
        }
        .padding(Theme.Space.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var spotlightBody: some View {
        VStack(spacing: Theme.Space.l) {
            ZStack {
                // The spot: a cone from above landing in a soft pool.
                SpotCone()
                    .fill(LinearGradient(colors: [Color.tungsten.opacity(0.0), Color.tungsten.opacity(0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 150, height: 120)
                    .mask(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: .white, location: 0.7),
                                                 .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .offset(y: -30)
                Ellipse()
                    .fill(RadialGradient(colors: [Color.tungsten.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 70))
                    .frame(width: 150, height: 34)
                    .offset(y: 30)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0xFFE2B0), .tungsten], startPoint: .top, endPoint: .bottom))
            }
            .frame(height: 96)
            VStack(spacing: Theme.Space.s) {
                Text(title).textRole(.title).multilineTextAlignment(.center)
                if let message {
                    Text(message).textRole(.body, color: .textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
            }
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String? = nil, style: EmptyStateStyle = .spotlight) {
        self.init(symbol: symbol, title: title, message: message, style: style) { EmptyView() }
    }
}

private struct SpotCone: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX + rect.width * 0.08, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

// MARK: - Banner

/// An inline message that lives in the layout (not floating). Tone sets the lamp color.
///
///     Banner(.warning, title: "Model not downloaded", message: "Download Soprano to perform.") {
///         Button("Download") { … }.buttonStyle(.secondary)
///     }
///     Banner(.danger, title: "Generation failed", message: error.localizedDescription, onDismiss: { error = nil })
struct Banner<Actions: View>: View {
    let tone: Tone
    let title: String
    var message: String?
    var onDismiss: (() -> Void)?
    @ViewBuilder var actions: Actions

    init(_ tone: Tone = .neutral, title: String, message: String? = nil,
         onDismiss: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions) {
        self.tone = tone
        self.title = title
        self.message = message
        self.onDismiss = onDismiss
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: tone.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tone.textColor)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textRole(.headline)
                if let message { Text(message).textRole(.caption).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Space.s) { actions }
            if let onDismiss {
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .buttonStyle(.icon)
                    .controlSize(.small)
            }
        }
        .padding(.leading, Theme.Space.l)
        .padding(.trailing, Theme.Space.m)
        .padding(.vertical, Theme.Space.m)
        .background {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            shape.fill(Color.surface)
                .overlay(shape.fill(LinearGradient(colors: [tone.color.opacity(0.13), tone.color.opacity(0.03)], startPoint: .leading, endPoint: .trailing)))
                .overlay(shape.strokeBorder(tone.color.opacity(0.28), lineWidth: 1))
                .overlay(alignment: .leading) {
                    Capsule().fill(tone.color).frame(width: 3).padding(.vertical, 9).padding(.leading, 5)
                }
        }
        .accessibilityElement(children: .contain)
    }
}

extension Banner where Actions == EmptyView {
    init(_ tone: Tone = .neutral, title: String, message: String? = nil, onDismiss: (() -> Void)? = nil) {
        self.init(tone, title: title, message: message, onDismiss: onDismiss) { EmptyView() }
    }
}

// MARK: - Toast

/// A transient message. Post through the `ToastCenter` in the environment; the shell draws it.
///
///     @Environment(ToastCenter.self) private var toasts
///     toasts.show("Saved to History", tone: .success)
struct Toast: Identifiable, Equatable {
    let id = UUID()
    var message: String
    var tone: Tone = .neutral
    var symbol: String?
}

/// Queue of transient toasts, injected into the environment by the app shell.
@Observable final class ToastCenter {
    private(set) var current: Toast?
    private var dismissTask: Task<Void, Never>?

    /// Shows a toast, replacing any visible one. It disappears after `duration` seconds.
    func show(_ message: String, tone: Tone = .neutral, symbol: String? = nil, duration: Double = 3) {
        dismissTask?.cancel()
        withStageAnimation(Theme.Motion.entrance) {
            current = Toast(message: message, tone: tone, symbol: symbol)
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        withStageAnimation(Theme.Motion.standard) { current = nil }
    }
}

/// The visual for a toast. You rarely need this directly; `ToastCenter` drives it.
struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: toast.symbol ?? toast.tone.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(toast.tone.textColor)
            Text(toast.message).textRole(.label, color: .textPrimary)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 36)
        .background {
            Capsule().fill(Color.surfaceRaised)
                .overlay(Capsule().strokeBorder(Color.hairlineStrong, lineWidth: 1))
        }
        .elevation()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension View {
    /// Draws toasts from the environment's `ToastCenter` at the bottom of this view.
    func toastOverlay(_ center: ToastCenter, bottomInset: CGFloat = Theme.Space.xl) -> some View {
        overlay(alignment: .bottom) {
            if let toast = center.current {
                ToastView(toast: toast)
                    .padding(.bottom, bottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
                    .onTapGesture { center.dismiss() }
            }
        }
    }
}

// MARK: - Sheet container

/// The body of a modal sheet: display title, close button, content, and a footer of actions
/// separated by a ticket perforation. Present with `.stageSheet`.
///
///     .stageSheet(isPresented: $showExport) {
///         SheetContainer(title: "Export take", subtitle: "Choose a format") {
///             SegmentedControl(selection: $fmt, options: formats) { $0 }
///         } actions: {
///             Button("Cancel") { showExport = false }.buttonStyle(.ghost)
///             Button("Export") { … }.buttonStyle(.primary)
///         }
///     }
struct SheetContainer<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 460
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.dismiss) private var dismiss

    init(title: String, subtitle: String? = nil, width: CGFloat = 460,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).textRole(.title)
                    if let subtitle { Text(subtitle).textRole(.caption) }
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .buttonStyle(.icon)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .top], Theme.Space.xl)
            .padding(.bottom, Theme.Space.l)

            VStack(alignment: .leading, spacing: Theme.Space.m) { content }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.bottom, Theme.Space.l)

            PerforatedDivider(bleed: 0)
                .padding(.horizontal, Theme.Space.xl)
            HStack(spacing: Theme.Space.s) {
                Spacer()
                actions
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.vertical, Theme.Space.l)
        }
        .frame(width: width)
        .background(Color.surface)
    }
}

extension View {
    /// Presents a modal sheet with Encore's surface and dark appearance.
    func stageSheet<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) {
            content()
                .presentationBackground(Color.surface)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Drop zone

/// A perforated well that accepts dropped files of the given types, and opens a file
/// picker when clicked. Lights up tungsten while a drag hovers over it.
///
///     DropZone(title: "Drop a reference clip", message: "WAV, MP3 or M4A · 5–30 seconds",
///              allowedTypes: [.audio]) { urls in clip = urls.first }
struct DropZone: View {
    var symbol: String = "waveform.badge.plus"
    let title: String
    var message: String?
    var allowedTypes: [UTType]
    var allowsMultiple: Bool = false
    var minHeight: CGFloat = 150
    let onDrop: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var isHovered = false
    @State private var isImporting = false

    init(symbol: String = "waveform.badge.plus", title: String, message: String? = nil,
         allowedTypes: [UTType], allowsMultiple: Bool = false, minHeight: CGFloat = 150,
         onDrop: @escaping ([URL]) -> Void) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.allowedTypes = allowedTypes
        self.allowsMultiple = allowsMultiple
        self.minHeight = minHeight
        self.onDrop = onDrop
    }

    private func accepts(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return allowedTypes.contains { type.conforms(to: $0) }
    }

    var body: some View {
        let lit = isTargeted
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
        Button { isImporting = true } label: {
            VStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(lit ? Color.tungsten : (isHovered ? .textSecondary : .textTertiary))
                    .scaleEffect(lit ? 1.12 : 1)
                Text(lit ? "Release to add" : title)
                    .textRole(.headline, color: lit ? .tungsten : .textPrimary)
                if let message { Text(message).textRole(.caption).multilineTextAlignment(.center) }
                Text("or click to browse").textRole(.caption, color: .textTertiary)
                    .padding(.top, 2)
            }
            .padding(Theme.Space.xl)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background {
                shape.fill(lit ? Color.tungsten.opacity(0.07) : Color.surfaceSunken.opacity(0.6))
                    .overlay(shape.strokeBorder(lit ? Color.tungsten : (isHovered ? Color.hairlineStrong : Color.textTertiary.opacity(0.45)),
                                                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [0.1, 7])))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = urls.filter(accepts)
            guard !accepted.isEmpty else { return false }
            onDrop(allowsMultiple ? accepted : [accepted[0]])
            return true
        } isTargeted: { isTargeted = $0 }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: allowedTypes, allowsMultipleSelection: allowsMultiple) { result in
            if case .success(let urls) = result, !urls.isEmpty { onDrop(urls) }
        }
        .stageAnimation(Theme.Motion.quick, value: isTargeted)
        .accessibilityLabel(title)
        .accessibilityHint("Drop a file here or activate to choose one")
    }
}
