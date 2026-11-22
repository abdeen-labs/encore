import AppKit
import EncoreCore
import SwiftUI

/// Pick the part of a recording to use as a cloning reference. Shows a file of any length (streamed peaks,
/// zoom, horizontal scroll and an overview strip) with a draggable selection bound to `selection`, a live
/// length readout against `target` (5–15 s by default) and "play selection". Long files are never a problem:
/// the user just chooses the stretch that sounds best.
///
///     WaveformTrimmer(url: droppedFile, selection: $clipRange)
///     WaveformTrimmer(url: droppedFile, selection: $clipRange, target: 5...15)
///     WaveformTrimmer(url: file, selection: $chosen, suggestsSelection: false)   // keep the caller's selection
///
/// Once the file is read it suggests the best-sounding stretch, unless `suggestsSelection` is false (the caller
/// already has a selection the user chose, e.g. the trimmer is reappearing).
///
/// Keyboard: ← → nudge the active edge (or the whole selection) by 0.1 s, ⇧ for 1 s; Space plays the selection.
struct WaveformTrimmer: View {
    let source: AudioSource
    @Binding var selection: ClosedRange<TimeInterval>
    var target: ClosedRange<TimeInterval> = 5...15
    var title: String?
    /// Suggest the best-sounding stretch once the file is read (off when the caller's selection should stay).
    var suggestsSelection = true
    /// When the whole file's length falls in this range, a "Use whole file" action selects all of it in one click.
    var wholeFileRange: ClosedRange<TimeInterval>?

    @State private var loader: WaveformLoader
    @State private var visible: ClosedRange<TimeInterval>?
    @State private var active: Edge = .body
    @State private var drag: DragState?
    @State private var player: AudioPlayer?
    @State private var didSuggest = false
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    @State private var zoomAnchorSpan: TimeInterval?
    @FocusState private var focused: Bool

    enum Edge { case start, end, body }
    private struct DragState { var mode: Mode; var startSelection: ClosedRange<TimeInterval>; var startVisible: ClosedRange<TimeInterval> }
    private enum Mode { case start, end, body, pan }

    init(url: URL, selection: Binding<ClosedRange<TimeInterval>>, target: ClosedRange<TimeInterval> = 5...15, title: String? = nil,
         suggestsSelection: Bool = true, wholeFileRange: ClosedRange<TimeInterval>? = nil) {
        source = .file(url)
        _selection = selection
        self.target = target
        self.title = title ?? url.lastPathComponent
        _loader = State(initialValue: WaveformLoader())
        self.suggestsSelection = suggestsSelection
        self.wholeFileRange = wholeFileRange
        _didSuggest = State(initialValue: !suggestsSelection)
    }

    /// Static peaks (previews, the gallery). Play is disabled.
    init(previewPeaks: WaveformPeaks, selection: Binding<ClosedRange<TimeInterval>>, target: ClosedRange<TimeInterval> = 5...15,
         title: String? = nil, visible: ClosedRange<TimeInterval>? = nil, wholeFileRange: ClosedRange<TimeInterval>? = nil) {
        source = .preview(previewPeaks)
        _selection = selection
        self.target = target
        self.title = title
        self.wholeFileRange = wholeFileRange
        _loader = State(initialValue: WaveformLoader(peaks: previewPeaks))
        _visible = State(initialValue: visible)
        _didSuggest = State(initialValue: true)
    }

    // MARK: Derived

    private var duration: TimeInterval { max(loader.duration, loader.peaks?.duration ?? 0) }
    private var length: TimeInterval { selection.upperBound - selection.lowerBound }
    private var verdict: Verdict {
        if duration > 0, duration < target.lowerBound - 0.05 { return .recordingTooShort }
        if length < target.lowerBound - 0.05 { return .tooShort }
        if length > target.upperBound + 0.05 { return .tooLong }
        return .good
    }
    private var tone: Color { verdict == .good ? .matcha : .honey }
    /// The file is already a usable length on its own: offer to take all of it.
    private var offersWholeFile: Bool {
        guard let wholeFileRange, duration > 0 else { return false }
        return wholeFileRange.contains(duration)
    }
    private var isWholeFile: Bool { selection.lowerBound <= 0.01 && selection.upperBound >= duration - 0.01 }
    private var isPlaying: Bool { player?.isPlaying ?? false && player?.activeRange != nil }

    private enum Verdict { case good, tooShort, tooLong, recordingTooShort }

    private var minimumSpan: TimeInterval { min(duration, 1.5) }
    private var shownRange: ClosedRange<TimeInterval> {
        if let visible { return visible }
        return defaultVisible
    }
    private var defaultVisible: ClosedRange<TimeInterval> {
        guard duration > 0 else { return 0...max(target.upperBound, 1) }
        if duration <= 60 { return 0...duration }
        let span = min(duration, max(30, length * 3))
        return clampVisible(center: (selection.lowerBound + selection.upperBound) / 2, span: span)
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            header
            if offersWholeFile && !isWholeFile {
                HStack(alignment: .center, spacing: Theme.Space.m) {
                    guidance.frame(maxWidth: .infinity, alignment: .leading)
                    wholeFileButton
                }
            } else {
                guidance
            }
            overview
            editor
            footer
        }
        .padding(Theme.Space.l)
        .surface(.card)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .space]) { press in handleKey(press) }
        .onContinuousHover { phase in
            if case .active = phase { isHovering = true } else { isHovering = false }
        }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
        .task(id: source.fileURL) {
            if let url = source.fileURL { await loader.load(url: url) }
        }
        .onChange(of: source.fileURL) { didSuggest = !suggestsSelection }
        .onChange(of: loader.peaks?.isComplete ?? false) { _, complete in
            if complete { suggestIfNeeded() }
        }
        .onChange(of: loader.duration) { _, d in
            // Keep the selection inside the media once its length is known.
            guard d > 0 else { return }
            if selection.upperBound > d || selection.lowerBound >= d { selection = 0...min(d, target.upperBound) }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Reference clip").textRole(.eyebrow)
                if let title { Text(title).textRole(.headline).lineLimit(1).truncationMode(.middle) }
                Text(fileFacts).textRole(.monoSmall, color: .textTertiary)
            }
            Spacer(minLength: Theme.Space.l)
            VStack(alignment: .trailing, spacing: 4) {
                Text(Timecode.seconds(length))
                    .textRole(.readout, color: verdict == .good ? Color.matchaInk : .honeyInk)
                    .contentTransition(.numericText())
                StatusBadge(badgeText, tone: verdict == .good ? .success : .warning)
            }
        }
    }

    private var fileFacts: String {
        var parts: [String] = []
        parts.append(duration > 0 ? Timecode.string(duration, tenths: duration < 60) : "Reading…")
        if loader.isLoading, let p = loader.peaks, duration > 0 {
            parts.append("analyzing \(Int(min(1, p.coveredDuration / duration) * 100))%")
        }
        return parts.joined(separator: "  ·  ")
    }

    private var badgeText: String {
        switch verdict {
        case .good: "Good length"
        case .tooShort: "Too short"
        case .tooLong: "Too long"
        case .recordingTooShort: "Short recording"
        }
    }

    private var guidance: some View {
        let lo = Int(target.lowerBound), hi = Int(target.upperBound)
        let text: String = switch verdict {
        case .good: "Ready to use. Play it back to check it's one clean voice."
        case .tooShort: "Drag a handle outward to select at least \(lo) seconds."
        case .tooLong: "Drag the handles in to keep the best \(lo) to \(hi) seconds."
        case .recordingTooShort: "Under \(lo) seconds. It may work, but \(lo) to \(hi) seconds clones better."
        }
        return Text(text).textRole(.caption, color: verdict == .good ? .textSecondary : .honeyInk)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var wholeFileButton: some View {
        Button("Use whole file", systemImage: "arrow.left.and.right") { useWholeFile() }
            .buttonStyle(.secondary)
            .controlSize(.small)
            .fixedSize()
            .help("The whole file is \(Timecode.seconds(duration)), already a good length: use all of it without moving the handles.")
    }

    /// The whole recording, small, with the selection and the visible window marked. Drag to move the view.
    private var overview: some View {
        GeometryReader { geo in
            let d = max(duration, 0.001)
            let x: (TimeInterval) -> CGFloat = { geo.size.width * $0 / d }
            let v = shownRange
            ZStack(alignment: .topLeading) {
                PeaksWaveform(peaks: loader.peaks, highlight: selection, tint: tone, gain: loader.displayGain,
                              barWidth: 1, gap: 1, duration: duration > 0 ? duration : nil)
                    .padding(.vertical, 3)
                // Visible window.
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.textPrimary.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.hairlineStrong, lineWidth: 1))
                    .frame(width: max(6, x(v.upperBound) - x(v.lowerBound)))
                    .offset(x: x(v.lowerBound))
                    .opacity(v.upperBound - v.lowerBound < d - 0.01 ? 1 : 0)
                // Selection tick.
                Rectangle().fill(tone)
                    .frame(width: max(2, x(selection.upperBound) - x(selection.lowerBound)), height: 2)
                    .offset(x: x(selection.lowerBound), y: geo.size.height - 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let span = v.upperBound - v.lowerBound
                visible = clampVisible(center: g.location.x / max(geo.size.width, 1) * d, span: span)
            })
        }
        .frame(height: 30)
        .padding(.horizontal, Theme.Space.s)
        .surface(.sunken, radius: Theme.Radius.s)
        .accessibilityLabel("Overview")
    }

    /// The zoomed view with the selection, its handles and a time ruler.
    private var editor: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let v = shownRange
                let span = max(v.upperBound - v.lowerBound, 0.001)
                let w = geo.size.width
                let x: (TimeInterval) -> CGFloat = { w * ($0 - v.lowerBound) / span }
                let sx = x(selection.lowerBound), ex = x(selection.upperBound)
                ZStack(alignment: .topLeading) {
                    PeaksWaveform(peaks: loader.peaks, range: v, highlight: selection, tint: tone, gain: loader.displayGain,
                                  barWidth: 2, gap: 1.5, duration: duration > 0 ? duration : nil)
                        .padding(.vertical, 10)
                    // Selected region.
                    Rectangle()
                        .fill(LinearGradient(colors: [tone.opacity(0.14), tone.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(0, ex - sx))
                        .offset(x: sx)
                        .allowsHitTesting(false)
                    handle(.start, at: sx, height: geo.size.height)
                    handle(.end, at: ex, height: geo.size.height)
                    if isPlaying, let t = player?.currentTime, v.contains(t) {
                        Playhead().offset(x: x(t))
                    }
                }
                .contentShape(Rectangle())
                .gesture(editorDrag(width: w))
                .simultaneousGesture(MagnifyGesture().onChanged { g in
                    let base = zoomAnchorSpan ?? span
                    if zoomAnchorSpan == nil { zoomAnchorSpan = span }
                    zoom(toSpan: base / g.magnification)
                }.onEnded { _ in zoomAnchorSpan = nil })
                .onContinuousHover { phase in
                    if case .active(let p) = phase {
                        if abs(p.x - sx) < 8 || abs(p.x - ex) < 8 { NSCursor.resizeLeftRight.set() }
                        else if p.x > sx && p.x < ex { NSCursor.openHand.set() }
                        else { NSCursor.arrow.set() }
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
            .frame(height: 118)
            .clipped()
            Ruler(range: shownRange)
                .frame(height: 18)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.top, Theme.Space.xs)
        .surface(.sunken, radius: Theme.Radius.m)
    }

    private func handle(_ edge: Edge, at xPos: CGFloat, height: CGFloat) -> some View {
        let isActive = active == edge && focused
        return ZStack {
            Rectangle().fill(tone).frame(width: isActive ? 2.5 : 2)
            RoundedRectangle(cornerRadius: 3)
                .fill(tone)
                .frame(width: 9, height: 26)
                .overlay {
                    VStack(spacing: 2.5) {
                        ForEach(0..<3, id: \.self) { _ in
                            Capsule().fill(Color.onTangerine.opacity(0.55)).frame(width: 4, height: 1.2)
                        }
                    }
                }
                .scaleEffect(isActive ? 1.12 : 1)
        }
        .frame(width: 12, height: height)
        .offset(x: xPos - 6)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.m) {
            Button(isPlaying ? "Stop" : "Play selection", systemImage: isPlaying ? "stop.fill" : "play.fill") { playSelection() }
                .buttonStyle(.play(isPlaying: isPlaying))
                .controlSize(.small)
                .disabled(!source.canPlay)
                .help(isPlaying ? "Stop" : "Play selection (Space)")
            HStack(spacing: 6) {
                Text(Timecode.string(selection.lowerBound)).textRole(.monoSmall)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.textTertiary)
                Text(Timecode.string(selection.upperBound)).textRole(.monoSmall)
            }
            Spacer(minLength: Theme.Space.s)
            ViewThatFits(in: .horizontal) {
                Text("← → nudge · ⇧ 1 s · Space plays").textRole(.caption, color: .textTertiary).lineLimit(1)
                Text("← → nudge").textRole(.caption, color: .textTertiary).lineLimit(1)
                Color.clear.frame(width: 0, height: 0)
            }
            .layoutPriority(-1)
            HStack(spacing: 2) {
                Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom(by: 2) }
                Button("Fit selection", systemImage: "arrow.left.and.right.square") { fitSelection() }
                Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom(by: 0.5) }
            }
            .buttonStyle(.icon)
            .controlSize(.small)
        }
    }

    // MARK: Interaction

    private func editorDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let v = drag?.startVisible ?? shownRange
                let span = v.upperBound - v.lowerBound
                let toTime: (CGFloat) -> TimeInterval = { v.lowerBound + Double($0 / max(width, 1)) * span }
                if drag == nil {
                    let sx = width * (selection.lowerBound - v.lowerBound) / span
                    let ex = width * (selection.upperBound - v.lowerBound) / span
                    let px = g.startLocation.x
                    let mode: Mode
                    if abs(px - sx) <= 9 && abs(px - sx) <= abs(px - ex) { mode = .start }
                    else if abs(px - ex) <= 9 { mode = .end }
                    else if px > sx && px < ex { mode = .body }
                    else { mode = .pan }
                    drag = DragState(mode: mode, startSelection: selection, startVisible: v)
                    focused = true
                    switch mode {
                    case .start: active = .start
                    case .end: active = .end
                    case .body: active = .body
                    case .pan: break
                    }
                }
                guard let d = drag else { return }
                let dt = Double(g.translation.width / max(width, 1)) * span
                let minLen = 0.2
                switch d.mode {
                case .start:
                    let s = min(max(0, toTime(g.location.x)), d.startSelection.upperBound - minLen)
                    selection = s...d.startSelection.upperBound
                case .end:
                    let e = max(min(duration, toTime(g.location.x)), d.startSelection.lowerBound + minLen)
                    selection = d.startSelection.lowerBound...e
                case .body:
                    let len = d.startSelection.upperBound - d.startSelection.lowerBound
                    let s = min(max(0, d.startSelection.lowerBound + dt), max(0, duration - len))
                    selection = s...(s + len)
                case .pan:
                    visible = clampVisible(center: (d.startVisible.lowerBound + d.startVisible.upperBound) / 2 - dt, span: span)
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.key == .space { playSelection(); return .handled }
        let step = press.modifiers.contains(.shift) ? 1.0 : 0.1
        let delta = press.key == .leftArrow ? -step : step
        let minLen = 0.2
        switch active {
        case .start:
            selection = min(max(0, selection.lowerBound + delta), selection.upperBound - minLen)...selection.upperBound
        case .end:
            selection = selection.lowerBound...max(min(duration, selection.upperBound + delta), selection.lowerBound + minLen)
        case .body:
            let len = length
            let s = min(max(0, selection.lowerBound + delta), max(0, duration - len))
            selection = s...(s + len)
        }
        revealSelection()
        return .handled
    }

    private func playSelection() {
        if isPlaying { player?.stop(); return }
        guard let url = source.fileURL else { return }
        Task {
            let p = player ?? AudioPlayer(title: title ?? url.lastPathComponent)
            if p.url != url {
                do { try await p.load(url: url, title: title) } catch { return }
            }
            p.subtitle = "Reference clip selection"
            p.waveform = loader.peaks
            player = p
            p.play(range: selection)
        }
    }

    /// Selects the entire file. A suggestion still on its way won't replace it.
    private func useWholeFile() {
        guard duration > 0 else { return }
        didSuggest = true
        if isPlaying { player?.stop() }
        withStageAnimation(Theme.Motion.quick) {
            selection = 0...duration
            visible = nil
        }
        active = .body
    }

    private func suggestIfNeeded() {
        guard !didSuggest, let peaks = loader.peaks else { return }
        didSuggest = true
        let ideal = min(target.upperBound, max(target.lowerBound, (target.lowerBound + target.upperBound) / 2))
        selection = peaks.suggestedSelection(length: ideal)
        visible = nil
    }

    // MARK: Zoom & scroll

    private func clampVisible(center: TimeInterval, span: TimeInterval) -> ClosedRange<TimeInterval> {
        let d = max(duration, 0.001)
        let s = min(max(span, minimumSpan), d)
        let lo = min(max(0, center - s / 2), d - s)
        return lo...(lo + s)
    }

    private func zoom(by factor: Double) {
        let v = shownRange
        zoom(toSpan: (v.upperBound - v.lowerBound) * factor)
    }

    private func zoom(toSpan span: TimeInterval) {
        let v = shownRange
        let selCenter = (selection.lowerBound + selection.upperBound) / 2
        let center = v.contains(selCenter) ? selCenter : (v.lowerBound + v.upperBound) / 2
        visible = clampVisible(center: center, span: span)
    }

    private func fitSelection() {
        visible = clampVisible(center: (selection.lowerBound + selection.upperBound) / 2, span: max(length * 1.6, 3))
    }

    private func revealSelection() {
        let v = shownRange
        guard !(v.contains(selection.lowerBound) && v.contains(selection.upperBound)) else { return }
        let edge = active == .start ? selection.lowerBound : (active == .end ? selection.upperBound : (selection.lowerBound + selection.upperBound) / 2)
        visible = clampVisible(center: edge, span: v.upperBound - v.lowerBound)
    }

    /// Horizontal scrolling (trackpad swipe, Shift+wheel) pans; ⌘+scroll zooms. Plain vertical scrolling is left
    /// to the page.
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering, duration > 0 else { return event }
            let v = shownRange
            let span = v.upperBound - v.lowerBound
            if event.modifierFlags.contains(.command) {
                zoom(toSpan: span * exp(-Double(event.scrollingDeltaY) * 0.01))
                return nil
            }
            let dx = event.modifierFlags.contains(.shift) && event.scrollingDeltaX == 0 ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(dx) > abs(event.scrollingDeltaY) * 0.8 || event.modifierFlags.contains(.shift) else { return event }
            let perPoint = span / 600
            visible = clampVisible(center: (v.lowerBound + v.upperBound) / 2 - Double(dx) * perPoint * (event.hasPreciseScrollingDeltas ? 1 : 8), span: span)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }
}

/// Time ruler under the trimmer's editor: tick spacing adapts to the zoom.
private struct Ruler: View {
    let range: ClosedRange<TimeInterval>

    var body: some View {
        Canvas { ctx, size in
            let span = max(range.upperBound - range.lowerBound, 0.001)
            let steps: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
            let step = steps.first { size.width / CGFloat(span / $0) >= 70 } ?? 3600
            var t = (range.lowerBound / step).rounded(.up) * step
            while t <= range.upperBound {
                let x = size.width * (t - range.lowerBound) / span
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: 4)), with: .color(Color.textTertiary.opacity(0.7)))
                let label = step < 1 ? Timecode.string(t) : Timecode.string(t, tenths: false)
                let text = Text(label).font(TextRole.monoSmall.font).foregroundStyle(Color.textTertiary)
                ctx.draw(text, at: CGPoint(x: x + 3, y: 5), anchor: .topLeading)
                t += step
            }
        }
        .accessibilityHidden(true)
    }
}
