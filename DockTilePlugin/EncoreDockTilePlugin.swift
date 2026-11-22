import AppKit

/// Draws Encore's chosen app icon in the Dock while Encore isn't running.
///
/// The Dock loads this bundle (named by `NSDockTilePlugIn` in the app's Info.plist) from `Contents/PlugIns` and keeps
/// it loaded, so the icon picked in Settings stays in the Dock after Encore quits. It reads the choice from Encore's
/// preferences (`DockIconShared.preferenceKey`, which `AppIconSwitcher` writes) and redraws when the app posts
/// `DockIconShared.changedNotification`. The default icon, and any Clear or Tinted icon style, are left to the
/// system: the plug-in only draws when an alternate is picked. While Encore runs, the app's own tile wins.
@MainActor
final class EncoreDockTilePlugin: NSObject, @preconcurrency NSDockTilePlugIn {
    private var tile: NSDockTile?
    private var appBundle: Bundle?
    private var domain: String?

    func setDockTile(_ dockTile: NSDockTile?) {
        DistributedNotificationCenter.default().removeObserver(self)
        tile = dockTile
        guard dockTile != nil else { return }
        // This bundle lives at Encore.app/Contents/PlugIns/EncoreDockTilePlugin.docktileplugin.
        let appURL = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app", let bundle = Bundle(url: appURL) else { return }
        appBundle = bundle
        domain = bundle.bundleIdentifier
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh), name: DockIconShared.changedNotification,
            object: domain, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(refresh), name: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, suspensionBehavior: .deliverImmediately)
        refresh()
    }

    @objc private func refresh() {
        guard let tile, let appBundle, let domain, let defaults = UserDefaults(suiteName: domain) else { return }
        defaults.synchronize()
        let choice = defaults.string(forKey: DockIconShared.preferenceKey) ?? ""
        if !DockIconShared.usesSystemIconStyle, let resource = DockIconShared.imageName(for: choice),
           let image = appBundle.image(forResource: resource) {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.image = image
            view.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}
