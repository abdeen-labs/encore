import EncoreCore
import SwiftUI

/// A service error turned into words and a way out: a tone, a short title, one or two sentences, and the
/// action that fixes it (if there is one). Use it anywhere an `Error` reaches the UI.
///
///     let p = ErrorPresentation(error)   // nil for cancellation
struct ErrorPresentation: Equatable {
    enum Action: Equatable {
        /// Open the Models screen (download, finish a download, pick a variant).
        case openModels
        /// Open Settings (the Python helper, ffmpeg).
        case openSettings
        /// Open the voice library.
        case openVoices

        var title: String {
            switch self {
            case .openModels: "Get it in Models"
            case .openSettings: "Open Settings"
            case .openVoices: "Open Voices"
            }
        }

        var section: AppSection {
            switch self {
            case .openModels: .models
            case .openSettings: .settings
            case .openVoices: .voices
            }
        }
    }

    var tone: Tone
    var title: String
    var message: String?
    var action: Action?

    /// Nil for cancellation, which is never an error worth showing.
    init?(_ error: Error) {
        if error is CancellationError { return nil }
        guard let e = error as? ServiceError else {
            tone = .danger
            title = "Something went wrong"
            message = Self.clip(error.localizedDescription)
            return
        }
        switch e {
        case .unknownModel:
            tone = .danger; title = "Unknown model"; message = e.errorDescription
        case .wrongTask:
            tone = .warning; title = "Wrong kind of model"; message = e.errorDescription
        case .modelNotDownloaded(_, _, let name, _, let partial):
            // The variant's label (bf16, 4-bit…) is engineering detail; the Models screen shows which one.
            tone = .warning
            title = partial ? "\(name) is only partly downloaded" : "\(name) isn't downloaded yet"
            message = partial ? "Finish the download in Models, then try again."
                : "Download it in Models, then try again."
            action = .openModels
        case .backendNeedsSetup(let runtime, let m):
            tone = .warning
            title = "\(runtime.displayName) needs setting up"
            message = "\(Self.sentence(m)) Set it up in Settings, or pick a model that runs natively."
            action = .openSettings
        case .backendUnavailable(let runtime, let m):
            tone = .danger
            title = "\(runtime.displayName) isn't available"
            message = Self.clip(Self.sentence(m))
            action = runtime == .python ? .openSettings : nil
        case .featureUnsupported(_, let name, let feature, let detail):
            tone = .warning
            title = "\(name) can't do \(Self.phrase(feature)) here"
            message = detail ?? "Pick a model that can."
        case .voiceMissing(let what):
            tone = .warning
            title = "Voice not found"
            message = "\(what) couldn't be found. It may have been deleted; pick another voice."
            action = .openVoices
        case .unknownPresetVoice(let name, _):
            tone = .warning
            title = "No voice called “\(name)”"
            message = "This model doesn't have that voice. Pick one of its own voices."
        case .unknownVoiceTags(let names):
            tone = .warning
            title = names.count == 1 ? "Nobody called “\(names[0])”" : "\(names.count) [voice:] tags name nobody"
            message = "No voice in your library or this model is called " + Self.list(names)
                + ". Fix the tag, or add the voice to your library."
            action = .openVoices
        case .emptyScript:
            tone = .neutral; title = "Nothing to say yet"; message = "Write something first."
        case .scriptProblem(let m):
            tone = .warning; title = "The script needs a fix"; message = m
        case .sourceUnreadable(let path, let reason):
            tone = .danger
            title = "Couldn't read \((path as NSString).lastPathComponent)"
            message = Self.clip(reason)
        case .noTranscriptionModel:
            tone = .warning
            title = "No transcription model"
            message = "Download Whisper or Parakeet in Models first."
            action = .openModels
        case .invalidRequest(let m):
            tone = .warning; title = "Can't do that"; message = Self.clip(m)
        case .generationFailed(let m):
            tone = .danger; title = "Generation failed"; message = Self.clip(m)
        }
    }

    private static func phrase(_ f: ServiceFeature) -> String {
        switch f {
        case .speech: "speech"
        case .cloning: "voice cloning"
        case .voiceDesign: "voice design"
        case .transcription: "transcription"
        case .wordTimestamps: "word timestamps"
        case .voiceConversion: "voice conversion"
        }
    }

    private static func list(_ names: [String]) -> String {
        let quoted = names.map { "“\($0)”" }
        guard quoted.count > 1 else { return quoted.first ?? "" }
        return quoted.dropLast().joined(separator: ", ") + " or " + quoted.last!
    }

    private static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return ".!?".contains(last) ? t : t + "."
    }

    /// Engine messages can be long tracebacks; keep the first line or two.
    static func clip(_ s: String) -> String {
        let firstLines = s.split(whereSeparator: \.isNewline).prefix(2).joined(separator: " ")
        return firstLines.count > 280 ? String(firstLines.prefix(280)) + "…" : firstLines
    }
}

/// An inline banner for a service error, with the action that fixes it.
///
///     if let error = runner.error {
///         ServiceErrorBanner(error: error, onDismiss: { runner.error = nil })
///     }
struct ServiceErrorBanner: View {
    let error: Error
    var onDismiss: (() -> Void)?
    /// Shown as a secondary button when the error might go away on a second try.
    var onRetry: (() -> Void)?

    @Environment(Router.self) private var router

    var body: some View {
        if let p = ErrorPresentation(error) {
            Banner(p.tone, title: p.title, message: p.message, onDismiss: onDismiss) {
                if let onRetry, p.tone == .danger {
                    Button("Try again", action: onRetry).buttonStyle(.ghost).controlSize(.small)
                }
                if let action = p.action {
                    Button(action.title) { router.go(action.section) }
                        .buttonStyle(.secondary)
                        .controlSize(.small)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
