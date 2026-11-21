import AppKit
import SwiftUI

/// Headless snapshot options parsed from the command line.
///
///     Encore --snapshot <dir>                         every section + the gallery
///     Encore --snapshot <dir> --snapshot-only Studio  one (or a comma list: Studio,Voices)
///     Encore --snapshot <dir> --full                  also write <Name>-full.png per section
///
/// Each target is written as `<dir>/<Name>.png`: the whole window (rail, stage, dock) at the
/// default window size, at 2x. `<Name>-full.png` is the screen alone, at the stage width and
/// its full content height. The gallery always gets both. Exit status is non-zero if a
/// name is unknown or a file cannot be written.
struct SnapshotConfig {
    var outputDirectory: URL
    var only: [String]?
    var fullHeight: Bool
    /// `--snapshot-size 940x600`: render the window at this size instead of the default.
    var size: CGSize?

    init?(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        let hasSnapshot = arguments.contains("--snapshot")
        let hasOnly = arguments.contains("--snapshot-only")
        guard hasSnapshot || hasOnly else { return nil }
        let dir = value(after: "--snapshot") ?? "snapshots"
        outputDirectory = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath,
                              relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
        only = value(after: "--snapshot-only")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        fullHeight = arguments.contains("--full")
        size = value(after: "--snapshot-size").flatMap { v in
            let p = v.lowercased().split(separator: "x").compactMap { Double($0) }
            return p.count == 2 ? CGSize(width: p[0], height: p[1]) : nil
        }
    }
}

/// A thing that can be snapshotted.
private enum SnapshotTarget {
    case section(AppSection)
    case gallery
    #if DEBUG
    /// Fixture states of a screen (see `FeatureFixture`). Not part of the default run; name them with --snapshot-only.
    case fixture(FeatureFixture)
    #endif

    var name: String {
        switch self {
        case .section(let s): s.rawValue
        case .gallery: "Gallery"
        #if DEBUG
        case .fixture(let f): f.name
        #endif
        }
    }

    static var all: [SnapshotTarget] {
        var targets = AppSection.allCases.map(SnapshotTarget.section)
        #if DEBUG
        targets.append(.gallery)
        #endif
        return targets
    }

    static var named: [SnapshotTarget] {
        #if DEBUG
        return all + FeatureFixture.all.map(SnapshotTarget.fixture)
        #else
        return all
        #endif
    }
}

@MainActor
enum SnapshotRunner {
    private static var delegate: SnapshotDelegate?

    static func run(_ config: SnapshotConfig) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        let delegate = SnapshotDelegate(config: config)
        self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}

private final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    let config: SnapshotConfig
    init(config: SnapshotConfig) { self.config = config }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let status = await render()
            exit(status)
        }
    }

    private func render() async -> Int32 {
        var targets = SnapshotTarget.all
        if let only = config.only {
            var picked: [SnapshotTarget] = []
            for name in only {
                guard let t = SnapshotTarget.named.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                    let known = SnapshotTarget.named.map(\.name).joined(separator: ", ")
                    FileHandle.standardError.write(Data("snapshot: unknown name '\(name)'. Known: \(known)\n".utf8))
                    return 2
                }
                picked.append(t)
            }
            targets = picked
        }

        do {
            try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("snapshot: cannot create \(config.outputDirectory.path): \(error)\n".utf8))
            return 1
        }

        var failed = false
        for target in targets {
            let windowSize = config.size ?? EncoreApp.defaultWindowSize
            let deps = AppDependencies(router: Router(section: {
                if case .section(let s) = target { return s }
                #if DEBUG
                if case .fixture(let f) = target { return f.section }
                #endif
                return .studio
            }()))
            if case .gallery = target { deps.router.isShowingGallery = true }
            #if DEBUG
            await StudioFixtures.prepare(deps)  // `--fixtures`: seeded temp stores (Features/Studio/StudioFixtures.swift)
            await VoiceFixtures.prepare(deps)  // `--voice-fixture`: Clone/Voices/Design states (Features/Voices/VoiceFixtures.swift)
            await ChangerFixtures.prepare(deps); await ConversationsFixtures.prepare(deps); await TranscribeFixtures.prepare(deps)  // `--<screen>-fixture <state>`
            #endif

            #if DEBUG
            if case .fixture(let fixture) = target {
                await fixture.seed?(deps)
                let o = fixture.prepare(deps)
                let content = fixture.sheet.map { $0(deps, o) } ?? AnyView(RootView())
                let view = content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.backdrop)
                    .environment(\.modelsLibraryOverride, o.library)
                    .environment(\.settingsModelOverride, o.settingsModel)
                    .appDependencies(deps)
                failed = !(await write(view, size: fixture.size ?? windowSize, name: target.name)) || failed
                continue
            }
            #endif
            let window = RootView().appDependencies(deps)
            failed = !(await write(window, size: windowSize, name: target.name)) || failed

            if config.fullHeight || { if case .gallery = target { return true }; return false }() {
                let stageWidth = windowSize.width - SidebarRail.width - Theme.Space.s
                let screen = screenView(for: target)
                    .environment(\.scaffoldScrolls, false)
                    .frame(width: stageWidth)
                    .background(StagePanel { Color.clear })
                    .appDependencies(deps)
                // Ideal height: propose an unspecified height so greedy views (editors,
                // spacers) report their ideal rather than eating whatever is offered.
                let measure = NSHostingView(rootView: screen.fixedSize(horizontal: false, vertical: true))
                measure.frame.size.width = stageWidth
                let height = min(measure.fittingSize.height, 16_000)
                failed = !(await write(screen, size: CGSize(width: stageWidth, height: max(200, ceil(height))), name: target.name + "-full")) || failed
            }
        }
        return failed ? 1 : 0
    }

    @ViewBuilder private func screenView(for target: SnapshotTarget) -> some View {
        switch target {
        case .section(let s): SectionScreen(section: s)
        case .gallery:
            #if DEBUG
            ComponentGallery()
            #else
            EmptyView()
            #endif
        #if DEBUG
        case .fixture(let f): SectionScreen(section: f.section)
        #endif
        }
    }

    /// Renders `view` offscreen at `size` (points) into a 2x PNG.
    private func write(_ view: some View, size: CGSize, name: String) async -> Bool {
        let root = view
            .environment(\.isSnapshotting, true)
            .preferredColorScheme(.dark)
            .frame(width: size.width, height: size.height)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)

        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Color.backdrop)
        window.contentView = hosting
        window.orderFrontRegardless()

        // Let layout, fonts, images and `.task`/`.onAppear` work settle: capture repeatedly
        // until two consecutive frames match (or give up after ~4 s).
        var previous: Data?
        var png: Data?
        for attempt in 0..<16 {
            try? await Task.sleep(for: .milliseconds(attempt == 0 ? 400 : 250))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let data = capture(hosting, size: size)
            if let data, data == previous {
                png = data
                if ProcessInfo.processInfo.environment["ENCORE_SNAPSHOT_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("snapshot: \(name) settled after \(attempt + 1) captures\n".utf8))
                }
                break
            }
            previous = data
            png = data
        }
        window.orderOut(nil)
        window.close()

        guard let png else {
            FileHandle.standardError.write(Data("snapshot: failed to render \(name)\n".utf8))
            return false
        }
        let url = config.outputDirectory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
            print(url.path)
            return true
        } catch {
            FileHandle.standardError.write(Data("snapshot: cannot write \(url.path): \(error)\n".utf8))
            return false
        }
    }

    private func capture(_ view: NSView, size: CGSize) -> Data? {
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
