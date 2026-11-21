import SwiftUI

/// The top-level sections of the app, in rail order.
enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case studio = "Studio"
    case clone = "Clone"
    case voices = "Voices"
    case design = "Design"
    case changer = "Changer"
    case conversations = "Conversations"
    case transcribe = "Transcribe"
    case history = "History"
    case models = "Models"
    case settings = "Settings"

    var id: String { rawValue }
    var title: String { rawValue }

    /// Rail grouping.
    enum Group: String, CaseIterable, Sendable {
        case perform = "Perform"
        case produce = "Produce"
        case backstage = "Backstage"
    }

    var group: Group {
        switch self {
        case .studio, .clone, .voices, .design: .perform
        case .changer, .conversations, .transcribe: .produce
        case .history, .models, .settings: .backstage
        }
    }

    /// One-line description, used as the default screen subtitle.
    var subtitle: String {
        switch self {
        case .studio: "Text to speech. Write the lines, cast a voice, perform."
        case .clone: "Make a voice from a short recording."
        case .voices: "Your company of voices."
        case .design: "Describe a voice and audition it into being."
        case .changer: "Speech to speech. Same performance, different voice."
        case .conversations: "Multi-speaker scripts, cast and staged."
        case .transcribe: "Speech to text, with timings."
        case .history: "Every take you have generated."
        case .models: "Download and manage on-device models."
        case .settings: "Preferences for Encore."
        }
    }

    /// SF Symbol for the rail.
    var symbol: String {
        switch self {
        case .studio: "text.bubble"
        case .clone: "mic"
        case .voices: "person.wave.2"
        case .design: "wand.and.stars"
        case .changer: "arrow.triangle.swap"
        case .conversations: "bubble.left.and.bubble.right"
        case .transcribe: "captions.bubble"
        case .history: "clock.arrow.circlepath"
        case .models: "cpu"
        case .settings: "slider.horizontal.3"
        }
    }

    /// ⌘-number shortcut (1…9) for the first nine sections; Settings uses ⌘,.
    var shortcutNumber: Int? {
        guard let index = Self.allCases.firstIndex(of: self), index < 9 else { return nil }
        return index + 1
    }

    var keyboardShortcut: KeyboardShortcut {
        if let n = shortcutNumber { return KeyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command) }
        return KeyboardShortcut(",", modifiers: .command)
    }

    /// Playbill-style eyebrow, e.g. "No. 03 · Perform".
    var eyebrow: String {
        let n = (Self.allCases.firstIndex(of: self) ?? 0) + 1
        return String(format: "No. %02d · %@", n, group.rawValue)
    }
}

/// App-wide navigation state.
///
///     @Environment(Router.self) private var router
///     router.go(.clone)
@Observable final class Router {
    /// The section on stage.
    var section: AppSection
    /// DEBUG only: the component gallery is showing instead of `section`.
    var isShowingGallery = false

    init(section: AppSection = .studio) {
        self.section = section
    }

    func go(_ section: AppSection) {
        withStageAnimation(Theme.Motion.quick) {
            self.section = section
            isShowingGallery = false
        }
    }

    func showGallery() {
        withStageAnimation(Theme.Motion.quick) { isShowingGallery = true }
    }
}
