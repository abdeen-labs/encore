import AppKit
import SwiftUI

/// Entry point. `--snapshot <dir>` renders screens to PNG headlessly and exits (see
/// `SnapshotRunner`); otherwise the normal SwiftUI app starts.
@main
enum Main {
    static func main() {
        #if DEBUG
        if StudioHeadless.isRequested { StudioHeadless.run() }  // Features/Studio/StudioHeadless.swift
        if VoiceHeadless.isRequested { VoiceHeadless.run() }  // Clone/Design/Voices proofs: Features/Voices/VoiceHeadless.swift
        if ProduceHeadless.isRequested { ProduceHeadless.run() }  // Changer, Conversations, Transcribe: Features/Changer/ProduceHeadless.swift
        if HistoryHeadless.isRequested { HistoryHeadless.run() }  // Features/History/HistoryHeadless.swift
        if ResetHeadless.isRequested { ResetHeadless.run() }  // Settings → Reset, temp roots only: Features/Settings/ResetHeadless.swift
        #endif
        if let config = SnapshotConfig(arguments: CommandLine.arguments) {
            SnapshotRunner.run(config)
        } else {
            EncoreApp.main()
        }
    }
}

struct EncoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var deps = AppDependencies()

    /// Default and minimum window sizes. Snapshots render at `defaultWindowSize`.
    static let defaultWindowSize = CGSize(width: 1180, height: 780)
    static let minimumWindowSize = CGSize(width: 940, height: 600)

    var body: some Scene {
        Window("Encore", id: "main") {
            RootView()
                .appDependencies(deps)
                .frame(minWidth: Self.minimumWindowSize.width, minHeight: Self.minimumWindowSize.height)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(Self.defaultWindowSize)
        .windowBackgroundDragBehavior(.enabled)
        .commands { EncoreCommands(router: deps.router) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One authored theme: the stage after dark.
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

/// Menu commands: Settings on ⌘, and a Go menu with ⌘1…⌘9.
struct EncoreCommands: Commands {
    let router: Router

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { router.go(.settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Go") {
            ForEach(AppSection.allCases.filter { $0.shortcutNumber != nil }) { section in
                Button(section.title) { router.go(section) }
                    .keyboardShortcut(section.keyboardShortcut)
            }
            #if DEBUG
            Divider()
            Button("Component Gallery") { router.showGallery() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            #endif
        }
    }
}
