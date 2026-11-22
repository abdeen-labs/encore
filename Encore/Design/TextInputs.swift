import SwiftUI

/// Shared chrome for text inputs: a sunken well that gets a soft tangerine ring on focus.
private struct InputWell: ViewModifier {
    var isFocused: Bool
    var isHovered: Bool
    var radius: CGFloat = Theme.Radius.s

    func body(content: Content) -> some View {
        content
            .surface(.sunken, radius: radius)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(isFocused ? Color.tangerine.opacity(0.85) : (isHovered ? .hairlineStrong : .clear), lineWidth: isFocused ? 2 : 1)
            }
            .background {
                // A soft halo outside the ring while focused.
                RoundedRectangle(cornerRadius: radius + 3, style: .continuous)
                    .fill(Color.tangerine.opacity(isFocused ? 0.16 : 0))
                    .padding(-3)
            }
            .stageAnimation(Theme.Motion.quick, value: isFocused)
    }
}

// MARK: - Text field

/// Single-line text input.
///
///     StageTextField("Voice name", text: $name)
///     StageTextField("Webhook", text: $url, symbol: "link", title: "Endpoint")
struct StageTextField: View {
    let placeholder: String
    @Binding var text: String
    var symbol: String?
    var title: String?
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ placeholder: String, text: Binding<String>, symbol: String? = nil, title: String? = nil, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.symbol = symbol
        self.title = title
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).textRole(.label, color: .textSecondary) }
            HStack(spacing: Theme.Space.s) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isFocused ? Color.tangerineInk : .textTertiary)
                }
                TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Color.textTertiary))
                    .textFieldStyle(.plain)
                    .font(TextRole.body.font)
                    .foregroundStyle(.textPrimary)
                    .focused($isFocused)
                    .onSubmit { onSubmit?() }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.ControlHeight.regular)
            .modifier(InputWell(isFocused: isFocused, isHovered: isHovered))
            .onHover { isHovered = $0 }
            .onTapGesture { isFocused = true }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Search field

/// Search input with a magnifier and a clear button.
///
///     SearchField(text: $query, prompt: "Search voices")
struct SearchField: View {
    @Binding var text: String
    var prompt: String = "Search"
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? Color.tangerineInk : .textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.textTertiary))
                .textFieldStyle(.plain)
                .font(TextRole.body.font)
                .foregroundStyle(.textPrimary)
                .focused($isFocused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button("Clear search", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.textTertiary)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.ControlHeight.regular)
        .modifier(InputWell(isFocused: isFocused, isHovered: isHovered, radius: Theme.ControlHeight.regular / 2))
        .onHover { isHovered = $0 }
        .onTapGesture { isFocused = true }
        .stageAnimation(Theme.Motion.quick, value: text.isEmpty)
    }
}

// MARK: - Script editor

/// A roomy multi-line editor for scripts and long prompts: generous line height, a placeholder,
/// and a monospaced word / character / read-time footer.
///
///     ScriptEditor(text: $script, placeholder: "Type the lines to perform…")
///     ScriptEditor(text: $notes, minHeight: 80, showsStats: false)
struct ScriptEditor: View {
    @Binding var text: String
    var placeholder: String = "Start writing…"
    var minHeight: CGFloat = 180
    var showsStats: Bool = true
    /// Words per minute used for the read-time estimate.
    var wordsPerMinute: Double = 160

    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var wordCount: Int { text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }

    private var readTime: String {
        let seconds = Int((Double(wordCount) / wordsPerMinute * 60).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(TextRole.script.font)
                    .lineSpacing(TextRole.script.lineSpacing)
                    .foregroundStyle(.textPrimary)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.automatic)
                    .contentMargins(.horizontal, 12, for: .scrollContent)
                    .contentMargins(.vertical, 12, for: .scrollContent)
                    .focused($isFocused)
                    .tint(.tangerine)
                if text.isEmpty {
                    Text(placeholder)
                        .textRole(.script, color: .textTertiary)
                        .padding(.horizontal, 17)
                        .padding(.top, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: minHeight, idealHeight: minHeight)
            if showsStats {
                HStack(spacing: Theme.Space.l) {
                    Text("\(wordCount) words")
                    Text("\(text.count) chars")
                    Spacer()
                    Text("≈ \(readTime)")
                        .foregroundStyle(wordCount > 0 ? Color.textSecondary : .textTertiary)
                }
                .font(TextRole.monoSmall.font)
                .foregroundStyle(.textTertiary)
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Hairline() }
            }
        }
        .modifier(InputWell(isFocused: isFocused, isHovered: isHovered, radius: Theme.Radius.m))
        .onHover { isHovered = $0 }
    }
}
