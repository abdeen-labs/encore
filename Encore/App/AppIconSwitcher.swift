import AppKit
import EncoreCore

/// Applies `AppSettings.appIcon` to the Dock. While Encore runs it sets the app's icon image; for when it isn't
/// running, it writes the choice where the Dock tile plug-in (`DockTilePlugin/`) reads it and tells the plug-in to
/// redraw, so the pick stays in the Dock after Encore quits. Finder and Launchpad show the bundle's icon (the bubble).
/// The default icon and Clear or Tinted icon styles are left to the system.
enum AppIconSwitcher {
    static func apply(_ icon: AppSettings.AppIcon) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: DockIconShared.preferenceKey) != icon.rawValue {
            defaults.set(icon.rawValue, forKey: DockIconShared.preferenceKey)
            defaults.synchronize()
            DistributedNotificationCenter.default().postNotificationName(
                DockIconShared.changedNotification, object: Bundle.main.bundleIdentifier, userInfo: nil,
                deliverImmediately: true)
        }
        let alternate = DockIconShared.usesSystemIconStyle ? nil : DockIconShared.imageName(for: icon.rawValue)
        NSApp.applicationIconImage = alternate.flatMap { NSImage(named: $0) }
    }

    /// The icon's artwork, for the picker in Settings.
    static func image(for icon: AppSettings.AppIcon) -> NSImage {
        switch icon {
        case .bubble: NSImage(named: "DockIconBubble") ?? NSImage()
        case .candy: NSImage(named: "DockIconCandy") ?? NSImage()
        }
    }

    static func name(_ icon: AppSettings.AppIcon) -> String {
        switch icon {
        case .bubble: "Bubble"
        case .candy: "Candy"
        }
    }
}
