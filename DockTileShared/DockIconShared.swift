import AppKit

/// What Encore and its Dock tile plug-in agree on: where the Dock icon choice is kept, how a change is announced,
/// and which image each choice draws. Compiled into both targets.
enum DockIconShared {
    /// The choice, as `AppSettings.AppIcon`'s raw value, in Encore's standard preferences.
    static let preferenceKey = "DockIcon"
    /// Posted (with Encore's bundle identifier as the object) when the choice changes.
    static let changedNotification = Notification.Name("dev.abdeen.encore.dockIconChanged")

    /// The asset catalog image for a choice; nil for the default icon, which the system draws.
    static func imageName(for choice: String) -> String? {
        switch choice {
        case "candy": "DockIconCandy"
        default: nil
        }
    }

    /// True when the person uses a Clear or Tinted icon style. Those are rendered by the system from the bundle's
    /// own icon, so an alternate image (which can't take the style) stands aside.
    static var usesSystemIconStyle: Bool {
        let theme = UserDefaults.standard.string(forKey: "AppleIconAppearanceTheme")?.lowercased() ?? ""
        return theme.contains("clear") || theme.contains("tinted") || theme.contains("mono")
    }
}
