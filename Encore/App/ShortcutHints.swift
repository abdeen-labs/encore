import AppKit
import SwiftUI

/// Whether the rail shows its keyboard-shortcut badges: true while Command (alone, or with Shift) has been held
/// for a moment with no other key pressed. A quick chord such as ⌘C never shows them; pressing any key, clicking,
/// releasing Command or switching away from the app hides them at once.
@MainActor @Observable
final class ShortcutHintMonitor {
    private(set) var isShowing = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// Set when a key or click is used with Command held; cleared when Command is released.
    @ObservationIgnored private var suppressed = false

    static let holdDelay: Duration = .milliseconds(450)

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.handle(event)
            return event
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reset() }
            })
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        reset()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            if Self.qualifies(event.modifierFlags) {
                if !suppressed && !isShowing && pending == nil { schedule() }
            } else {
                // Command released, or another modifier joined (⌥⌘, ⌃⌘): start over.
                if !event.modifierFlags.contains(.command) { suppressed = false }
                else { suppressed = true }
                hide()
            }
        default:
            // A key or click while Command is down is a chord, not a request for hints.
            if event.modifierFlags.contains(.command) { suppressed = true }
            hide()
        }
    }

    private func schedule() {
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.holdDelay)
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            // Re-check the live state: a release can go unseen if it happened in another app.
            guard !self.suppressed, NSApp.isActive, Self.qualifies(NSEvent.modifierFlags) else { return }
            self.isShowing = true
        }
    }

    private func hide() {
        pending?.cancel()
        pending = nil
        if isShowing { isShowing = false }
    }

    private func reset() {
        suppressed = false
        hide()
    }

    /// Command alone, or Command with Shift (the gallery's ⇧⌘G).
    private static func qualifies(_ flags: NSEvent.ModifierFlags) -> Bool {
        let f = flags.intersection([.command, .shift, .option, .control, .function])
        return f == .command || f == [.command, .shift]
    }
}

/// A keycap: the key a shortcut uses, shown while Command is held.
struct KeycapBadge: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.mono(10.5, weight: .medium))
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .fill(Color.surfaceRaised)
                    .shadow(color: .black.opacity(0.5), radius: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous)
                    .strokeBorder(Color.hairlineStrong, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// Snapshot fixtures: draw the rail's shortcut badges as if Command were held.
    @Entry var forcesShortcutHints: Bool = false
}
