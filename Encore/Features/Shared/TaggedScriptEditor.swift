import AppKit
import EncoreCore
import SwiftUI

/// Lets other views act on a `TaggedScriptEditor`: insert at the cursor, focus it.
///
///     let editor = ScriptEditorController()
///     TaggedScriptEditor(text: $script, parsed: plan.parsed, controller: editor)
///     TagInserter(manifest: manifest, voices: …) { editor.insert($0) }
@MainActor final class ScriptEditorController {
    fileprivate weak var textView: NSTextView?

    init() {}

    /// Inserts `snippet` at the cursor (replacing any selection) with a space on either side where the
    /// neighboring text needs one. Undoable; the text binding updates as if typed.
    func insert(_ snippet: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let range = tv.selectedRange()
        var s = snippet
        if range.location > 0 {
            let before = ns.substring(with: NSRange(location: range.location - 1, length: 1))
            if !(before.first?.isWhitespace ?? true) { s = " " + s }
        }
        let end = range.location + range.length
        if end < ns.length {
            let after = ns.substring(with: NSRange(location: end, length: 1))
            if let c = after.first, !c.isWhitespace, !".,;:!?)]".contains(c) { s += " " }
        }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(s, replacementRange: range)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }

    /// Selects a UTF-16 range (e.g. a script issue) and scrolls to it.
    func select(_ range: NSRange) {
        guard let tv = textView, NSMaxRange(range) <= (tv.string as NSString).length else { return }
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(range)
        tv.scrollRangeToVisible(range)
    }
}

/// The script editor with live tag highlighting in two styles: pause and expressive tags as quiet markup (mono,
/// secondary text, a faint raised background), voice cues (`[voice: Name]`) in gel. Anything tag-shaped the model
/// won't understand keeps the footlight underline, and the planner's issues are underlined too.
/// Highlighting comes from a `ParsedScript` the caller already has (e.g. `ScriptPlan.parsed`), so the editor
/// shows exactly what will be performed.
///
///     TaggedScriptEditor(text: $script, parsed: plan.parsed, controller: editor,
///                        placeholder: "Write the lines…", onCommandReturn: perform)
struct TaggedScriptEditor: View {
    @Binding var text: String
    var parsed: ParsedScript?
    var controller: ScriptEditorController?
    var placeholder: String = "Write the lines to perform…"
    var fontSize: CGFloat = 15
    /// ⌘↩ inside the editor (the text view would otherwise swallow it).
    var onCommandReturn: (() -> Void)?
    /// ⌘. inside the editor.
    var onCommandPeriod: (() -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            ScriptTextViewRepresentable(text: $text, parsed: parsed, controller: controller, fontSize: fontSize,
                                        onCommandReturn: onCommandReturn, onCommandPeriod: onCommandPeriod)
            if text.isEmpty {
                // Same face and size as the script it stands in for.
                Text(placeholder)
                    .font(.ui(fontSize))
                    .foregroundStyle(.textTertiary)
                    .padding(.horizontal, ScriptTextViewRepresentable.inset.width + 2)
                    .padding(.top, ScriptTextViewRepresentable.inset.height - 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// How tags look in a script. Two styles: markup (pause, expressive and unrecognized tags: secondary text on a
/// faint raised background) and voice cues (gel). An unrecognized tag adds `problemColor` as an underline.
///
///     a[r].foregroundColor = ScriptTagStyle.color(tag.kind)
///     a[r].backgroundColor = ScriptTagStyle.background(tag.kind)
enum ScriptTagStyle {
    /// The tag's text color.
    static func color(_ kind: ScriptTagKind) -> Color {
        switch kind {
        case .voice: .gel
        case .pause, .expressive, .unrecognized: .textSecondary
        }
    }

    /// The faint fill behind the tag.
    static func background(_ kind: ScriptTagKind) -> Color {
        switch kind {
        case .voice: Color.gel.opacity(0.11)
        case .pause, .expressive, .unrecognized: .surfaceRaised
        }
    }

    /// The underline under a tag the model won't understand.
    static var problemColor: Color { .footlight }
}

private struct ScriptTextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    var parsed: ParsedScript?
    var controller: ScriptEditorController?
    var fontSize: CGFloat
    var onCommandReturn: (() -> Void)?
    var onCommandPeriod: (() -> Void)?

    static let inset = CGSize(width: 16, height: 14)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder

        let tv = ScriptTextView()
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 2
        tv.textContainerInset = Self.inset
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(Color.tungsten)
        tv.selectedTextAttributes = [.backgroundColor: NSColor(Color.tungsten.opacity(0.28))]
        tv.typingAttributes = context.coordinator.baseAttributes(fontSize)
        tv.delegate = context.coordinator
        tv.string = text
        scroll.documentView = tv

        context.coordinator.textView = tv
        controller?.textView = tv
        apply(to: tv, coordinator: context.coordinator, force: true)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ScriptTextView else { return }
        controller?.textView = tv
        tv.onCommandReturn = onCommandReturn
        tv.onCommandPeriod = onCommandPeriod
        context.coordinator.text = $text
        if tv.string != text {
            let selection = tv.selectedRange()
            tv.string = text
            let length = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            apply(to: tv, coordinator: context.coordinator, force: true)
        } else {
            apply(to: tv, coordinator: context.coordinator, force: false)
        }
    }

    /// Re-colors the text when the parse result changed (and matches the text on screen).
    private func apply(to tv: NSTextView, coordinator: Coordinator, force: Bool) {
        guard let storage = tv.textStorage else { return }
        let signature = Coordinator.signature(parsed, fontSize: fontSize)
        guard force || signature != coordinator.lastSignature else { return }
        let length = storage.length
        // Only color a parse of exactly this text; a stale one would paint the wrong ranges.
        let parsed = (self.parsed.map { p in p.tags.allSatisfy { NSMaxRange($0.utf16Range) <= length } } ?? false) ? self.parsed : nil
        coordinator.lastSignature = signature
        let base = coordinator.baseAttributes(fontSize)
        storage.beginEditing()
        storage.setAttributes(base, range: NSRange(location: 0, length: length))
        if let parsed {
            let tagFont = NSFont.monospacedSystemFont(ofSize: fontSize - 2.5, weight: .regular)
            for tag in parsed.tags where NSMaxRange(tag.utf16Range) <= length {
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(ScriptTagStyle.color(tag.kind)),
                                                            .font: tagFont,
                                                            .backgroundColor: NSColor(ScriptTagStyle.background(tag.kind))]
                if tag.kind == .unrecognized {
                    attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                    attrs[.underlineColor] = NSColor(ScriptTagStyle.problemColor)
                }
                storage.addAttributes(attrs, range: tag.utf16Range)
            }
            for issue in parsed.issues where issue.severity != .info && NSMaxRange(issue.utf16Range) <= length {
                let color = NSColor(issue.severity == .error ? Color.velvetText : Color.footlight)
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: color,
                                       .toolTip: issue.message], range: issue.utf16Range)
            }
        }
        storage.endEditing()
        tv.typingAttributes = base
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var textView: NSTextView?
        var lastSignature: Int?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if text.wrappedValue != tv.string { text.wrappedValue = tv.string }
        }

        func baseAttributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 6
            paragraph.paragraphSpacing = 2
            let font = NSFont(name: "AvenirNext-Regular", size: size) ?? .systemFont(ofSize: size)
            return [.font: font, .foregroundColor: NSColor(Color.textPrimary), .paragraphStyle: paragraph]
        }

        static func signature(_ parsed: ParsedScript?, fontSize: CGFloat) -> Int {
            var h = Hasher()
            h.combine(fontSize)
            for t in parsed?.tags ?? [] { h.combine(t.kind); h.combine(t.utf16Range.location); h.combine(t.utf16Range.length) }
            for i in parsed?.issues ?? [] { h.combine(i.severity); h.combine(i.utf16Range.location); h.combine(i.utf16Range.length) }
            return h.finalize()
        }
    }
}

/// NSTextView that hands ⌘↩ and ⌘. to the screen instead of inserting a newline / beeping.
private final class ScriptTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onCommandPeriod: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, let onCommandReturn {
            onCommandReturn(); return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers == ".", let onCommandPeriod {
            onCommandPeriod(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
