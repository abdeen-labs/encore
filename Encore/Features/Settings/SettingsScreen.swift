import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences, in sections separated by a hairline: the Hugging Face account, memory, output, pronunciations,
/// storage, the plumbing (ffmpeg, the Python helper, where the token is kept) behind Advanced, about, and the two
/// reset actions at the very bottom.
struct SettingsScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(HubAccountModel.self) private var account
    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(RuntimeStatus.self) private var runtimeStatus
    @Environment(EncoreService.self) private var service
    @Environment(\.settingsModelOverride) private var modelOverride
    @Environment(\.isSnapshotting) private var isSnapshotting
    @State private var ownModel = SettingsModel()

    private var model: SettingsModel { modelOverride ?? ownModel }

    var body: some View {
        ScreenScaffold(.settings) {
            VStack(alignment: .leading, spacing: 0) {
                HuggingFaceSection()
                MemorySection()
                OutputSection(ffmpegFound: model.ffmpeg != nil || !model.ffmpegChecked)
                PronunciationsSection()
                StorageSection(model: model)
                AdvancedSection(model: model)
                AboutSection()
                ResetSection(onReset: refreshStorage)
            }
        }
        .task {
            await account.refresh()  // fixture-safe; snapshots use an isolated token store
            guard !model.isFixture, !isSnapshotting else { return }
            model.refreshFFmpeg(configuredPath: settings.ffmpegPath)
            await model.refreshPython(service: service)
            await downloads.refresh(verifyOnline: false)
            await refreshStorage()
        }
        .onChange(of: settings.ffmpegPath) { model.refreshFFmpeg(configuredPath: settings.ffmpegPath) }
    }

    private func refreshStorage() async {
        guard !model.isFixture, !isSnapshotting else { return }
        await model.refreshStorage(modelsBytes: downloads.totalBytesOnDisk, hubCache: downloads.downloader.store.layout.root)
    }
}

// MARK: - Section chrome

/// A settings section: its name and one caption on the left, the controls on the right. Sections are separated by
/// space and a hairline (`divided`); the first one on the screen, or in a group, leaves the rule off.
struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    var divided: Bool = true
    @ViewBuilder var content: Content

    init(title: String, subtitle: String? = nil, divided: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.divided = divided; self.content = content()
    }

    static var gap: CGFloat { Theme.Space.l + Theme.Space.xs }
    static var labelWidth: CGFloat { 180 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if divided { Hairline().padding(.bottom, Self.gap) }
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(title).textRole(.section)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: Self.labelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.m) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, divided ? Self.gap : 0)
        .padding(.bottom, Self.gap)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line that asks for something: a warning glyph, a sentence, and the action that fixes it.
/// Problems that need action only; information is a caption.
struct AttentionLine<Actions: View>: View {
    let text: String
    var tone: Tone = .warning
    @ViewBuilder var actions: Actions

    init(_ text: String, tone: Tone = .warning, @ViewBuilder actions: () -> Actions) {
        self.text = text; self.tone = tone; self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.s) {
            Image(systemName: tone.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone.textColor)
            Text(text).textRole(.caption, color: .textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Space.xs) { actions }
                .fixedSize()
        }
    }
}

extension AttentionLine where Actions == EmptyView {
    init(_ text: String, tone: Tone = .warning) {
        self.init(text, tone: tone) { EmptyView() }
    }
}

/// Where the shared Hugging Face token file lives, abbreviated.
private enum HubTokenFile {
    static var path: String {
        (EncorePaths.huggingFaceTokenFile.path as NSString).abbreviatingWithTildeInPath
    }
}

/// The ffmpeg install command, copied by the buttons that offer it.
private enum FFmpegInstall {
    static let command = "brew install ffmpeg"

    @MainActor static func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @MainActor static func choose(into settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.title = "Choose ffmpeg"
        panel.message = "Pick the ffmpeg program, or the folder that contains it."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        if panel.runModal() == .OK, let url = panel.url { settings.ffmpegPath = url.path }
    }
}

// MARK: - Hugging Face

private struct HuggingFaceSection: View {
    @Environment(HubAccountModel.self) private var account
    @Environment(EncoreService.self) private var service
    @Environment(ToastCenter.self) private var toasts
    @State private var token = ""
    @State private var replacing = false
    @State private var confirmingSignOut = false
    @State private var saveFailed = false
    @State private var isSaving = false

    var body: some View {
        SettingsSection(title: "Hugging Face", subtitle: "Needed for gated models; speeds up every download.", divided: false) {
            switch account.status {
            case .signedIn(let a):
                signedIn(a)
            case .checking:
                HStack(spacing: Theme.Space.s) {
                    ActivityIndicator(size: 14)
                    Text("Checking your token with Hugging Face…").textRole(.caption)
                }
            case .invalidToken:
                AttentionLine("Hugging Face rejected the saved token. Paste a new one, or sign out.", tone: .danger) {
                    signOutButton
                }
                tokenEntry(prompt: "Paste a new token")
            case .unreachable(let message):
                AttentionLine("Couldn't reach Hugging Face. Your token is kept.") {
                    Button("Try again") { Task { await account.refresh() } }.buttonStyle(.secondary).controlSize(.small)
                    signOutButton
                }
                .help(message)
            case .signedOut, .unknown:
                if account.isSignedOutOfEncoreOnly { encoreOnlyNotice }
                tokenEntry(prompt: "Paste a read token (hf_…)")
            }
            if let source = account.tokenSource, source == .environment {
                Text("Using HF_TOKEN from the environment, which takes precedence over the saved token.")
                    .textRole(.caption, color: .textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .stageSheet(isPresented: $confirmingSignOut) {
            SignOutSheet(tokenPath: HubTokenFile.path, everywhere: signOutEverywhere, encoreOnly: signOutOfEncoreOnly)
        }
    }

    /// Shown while signed out of Encore only, when the shared token file may still hold a token.
    private var encoreOnlyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(account.sharedTokenFileExists
                 ? "Signed out of Encore only. The hf tool's token is still on this Mac; Encore ignores it until you sign in here."
                 : "Signed out of Encore only. Encore won't use the hf tool's token until you sign in here.")
                .textRole(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .help(HubTokenFile.path)
            Spacer(minLength: Theme.Space.s)
            if account.sharedTokenFileExists {
                Button("Use that token") { Task { await account.useSharedToken() } }
                    .buttonStyle(.secondary).controlSize(.small)
                    .fixedSize()
            }
        }
    }

    private func signedIn(_ a: HubAccount) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Avatar(account: a)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Space.s) {
                        Text(a.fullName ?? a.name).textRole(.headline)
                        StatusBadge("Signed in", tone: .success)
                    }
                    Text("@\(a.name)" + (a.tokenName.map { " · token “\($0)”" } ?? "")).textRole(.caption)
                }
                Spacer(minLength: Theme.Space.s)
            }
            if replacing {
                tokenEntry(prompt: "Paste the new token")
            } else {
                HStack(spacing: Theme.Space.s) {
                    Button("Replace token") { replacing = true }.buttonStyle(.secondary).controlSize(.small)
                    signOutButton
                    Spacer()
                }
            }
        }
    }

    static let tokensURL = URL(string: "https://huggingface.co/settings/tokens")!

    private func tokenEntry(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                TokenField(prompt: prompt, text: $token, onSubmit: save)
                Button("Save", action: save)
                    .buttonStyle(.primary)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                if replacing {
                    Button("Cancel") { replacing = false; token = "" }.buttonStyle(.ghost)
                }
            }
            HStack(spacing: Theme.Space.s) {
                if saveFailed {
                    Text(account.status == .invalidToken ? "That token was rejected. Nothing was saved."
                                                         : "Couldn't check that token. Nothing was saved.")
                        .textRole(.caption, color: .velvetText)
                }
                Spacer()
                LinkButton(title: "Create a token", url: Self.tokensURL)
            }
        }
    }

    private func save() {
        let candidate = token
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSaving = true
        Task {
            let ok = await account.setToken(candidate)
            isSaving = false
            saveFailed = !ok
            if ok { token = ""; replacing = false }
        }
    }

    private var signOutButton: some View {
        Button("Sign out…") { confirmingSignOut = true }.buttonStyle(.ghost).controlSize(.small)
    }

    private func signOutEverywhere() {
        account.signOut()
        replacing = false
        token = ""
    }

    private func signOutOfEncoreOnly() {
        guard account.signOutOfEncoreOnly() else {
            toasts.show("Encore couldn't update its Keychain item, so you're still signed in.", tone: .danger, duration: 6)
            return
        }
        replacing = false
        token = ""
        // A running helper was started with the shared token file visible; restart it (when idle) without it.
        Task { for case let python as PythonBackend in service.backends { await python.shutdownIfIdle() } }
    }
}

/// Asks how far to sign out: everywhere on this Mac (the default; deletes the shared token file), or Encore only.
struct SignOutSheet: View {
    let tokenPath: String
    let everywhere: () -> Void
    let encoreOnly: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetContainer(title: "Sign out of Hugging Face?", width: 520) {
            option(title: "Sign out everywhere", symbol: "rectangle.portrait.and.arrow.right",
                   detail: "Removes the token from your Keychain and deletes \(tokenPath). Everything on this Mac that uses that shared file is signed out too, including the hf command-line tool.")
            option(title: "Sign out of Encore only", symbol: "key.slash",
                   detail: "Removes Encore's copy from your Keychain and leaves \(tokenPath) alone, so the hf tool stays signed in. Encore stays signed out, even after you quit it, until you sign in here again.")
        } actions: {
            Button("Cancel") { dismiss() }
                .buttonStyle(.ghost)
                .keyboardShortcut(.cancelAction)
            Button("Sign out of Encore only") { encoreOnly(); dismiss() }
                .buttonStyle(.secondary)
            Button("Sign out everywhere") { everywhere(); dismiss() }
                .buttonStyle(.destructive)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func option(title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).textRole(.headline)
                Text(detail).textRole(.caption, color: .textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.sunken, radius: Theme.Radius.m)
    }
}

/// A masked, paste-friendly token input in the kit's sunken well. The value is never shown.
private struct TokenField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "key.horizontal").font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Color.textSecondary : .textTertiary)
            SecureField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.textTertiary))
                .textFieldStyle(.plain)
                .textRole(.mono)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Text("\(text.trimmingCharacters(in: .whitespacesAndNewlines).count) chars").textRole(.monoSmall, color: .textTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.ControlHeight.regular)
        .surface(.sunken, radius: Theme.Radius.s)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous)
            .strokeBorder(focused ? Color.tungsten.opacity(0.75) : .clear, lineWidth: 1))
        .onTapGesture { focused = true }
    }
}

private struct Avatar: View {
    let account: HubAccount
    @Environment(\.isSnapshotting) private var isSnapshotting

    var body: some View {
        ZStack {
            Circle().fill(Color.surfaceRaised)
            // Until the picture loads (or when there is none): a person, not an initial.
            Image(systemName: "person.fill")
                .font(.system(size: 15))
                .foregroundStyle(.textSecondary)
            if let url = account.avatarURL, !isSnapshotting {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: 36, height: 36)
        .overlay(Circle().strokeBorder(Color.hairlineStrong))
        .accessibilityHidden(true)
    }
}

// MARK: - Memory

private struct MemorySection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RuntimeStatus.self) private var status
    @Environment(Router.self) private var router

    private static let choices = [5, 10, 15, 30, 60, 0]

    var body: some View {
        @Bindable var settings = settings
        SettingsSection(title: "Memory",
                        subtitle: "This Mac has \(Bytes.memory(status.memory.physicalBytes)) of memory. Models stay loaded while you work; idle ones make room for the next.") {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("Unload idle models after").textRole(.label, color: .textSecondary)
                Spacer()
                MenuPicker(selection: $settings.idleUnloadMinutes,
                           options: Self.choices.contains(settings.idleUnloadMinutes) ? Self.choices : Self.choices + [settings.idleUnloadMinutes]) {
                    $0 == 0 ? "Never" : ($0 >= 60 ? "\($0 / 60) hour" : "\($0) minutes")
                }
                .frame(width: 150)
            }
            Button { router.go(.models) } label: {
                HStack(spacing: Theme.Space.xs) {
                    Text("See what's loaded in Models")
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.ghost).controlSize(.small)
            .padding(.leading, -Theme.Space.s)
        }
    }
}

// MARK: - Output

private struct OutputSection: View {
    let ffmpegFound: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsSection(title: "Output", subtitle: "Defaults for new takes and exports.") {
            HStack(spacing: Theme.Space.m) {
                Text("Export format").textRole(.label, color: .textSecondary)
                Spacer()
                SegmentedControl(selection: $settings.defaultExportFormat, options: AppSettings.ExportFormat.allCases) {
                    $0.rawValue.uppercased()
                }
                .fixedSize()
            }
            if settings.defaultExportFormat == .mp3 && !ffmpegFound {
                AttentionLine("MP3 export needs ffmpeg, which Encore can't find.") {
                    Button("Copy install command", systemImage: "doc.on.doc") { FFmpegInstall.copyCommand() }
                        .buttonStyle(.ghost).controlSize(.small)
                        .help(FFmpegInstall.command)
                }
            }
            Toggle("Normalize loudness", isOn: $settings.postProcessing.normalizeLoudness).toggleStyle(.stage)
            if settings.postProcessing.normalizeLoudness {
                StageSlider("Target loudness", value: $settings.postProcessing.targetLUFS, in: -24 ... -9, step: 1,
                            defaultValue: -16) { String(format: "%.0f LUFS", $0) }
                    .help("−16 LUFS suits podcasts and voice-over; −14 is louder, for streaming platforms.")
            }
            Toggle("Trim silences", isOn: $settings.postProcessing.removeSilence).toggleStyle(.stage)
            if settings.postProcessing.removeSilence {
                StageSlider("Longest pause kept", value: $settings.postProcessing.maxSilenceSeconds, in: 0.2...2, step: 0.05,
                            defaultValue: 0.6) { String(format: "%.2f s", $0) }
            }
        }
    }
}

// MARK: - Pronunciations

/// The shared pronunciation list (the same sheet Studio and Conversations open).
private struct PronunciationsSection: View {
    @Environment(PronunciationStore.self) private var store
    @State private var showEditor = false

    var body: some View {
        let enabled = store.entries.filter(\.enabled).count
        SettingsSection(title: "Pronunciations", subtitle: "Names, jargon and acronyms every voice should say your way.") {
            HStack(spacing: Theme.Space.m) {
                Text(store.entries.isEmpty ? "No pronunciations yet"
                     : "\(store.entries.count) \(store.entries.count == 1 ? "entry" : "entries"), \(enabled) on")
                    .textRole(.label, color: .textSecondary)
                Spacer()
                Button("Edit pronunciations…") { showEditor = true }
                    .buttonStyle(.secondary).controlSize(.small)
            }
        }
        .pronunciationSheet(isPresented: $showEditor)
    }
}

// MARK: - Storage

private struct StorageSection: View {
    let model: SettingsModel

    var body: some View {
        SettingsSection(title: "Storage", subtitle: "Where Encore keeps things on this Mac.") {
            if model.storage.isEmpty {
                Text("Measuring…").textRole(.caption)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.storage.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    HStack(spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).textRole(.headline)
                            Text((item.url.path as NSString).abbreviatingWithTildeInPath).textRole(.monoSmall, color: .textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(item.detail)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Text(item.bytes.map(Bytes.file) ?? "…").textRole(.mono, color: .textSecondary)
                        Button("Show \(item.title) in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([item.url])
                        }
                        .buttonStyle(.icon).labelStyle(.iconOnly).controlSize(.small)
                        .help("Show in Finder")
                    }
                    .padding(.vertical, Theme.Space.s)
                }
            }
            .padding(.top, -Theme.Space.s)
        }
    }
}

// MARK: - Advanced

/// The plumbing, closed by default: ffmpeg, the Python helper, and where the token is kept. When one of them needs
/// the user's action, a one-line warning says so above the disclosure.
private struct AdvancedSection: View {
    let model: SettingsModel
    @Environment(AppSettings.self) private var settings
    @State private var expanded = false

    private var ffmpegPathMissing: Bool {
        settings.ffmpegPath != nil && model.ffmpegChecked && model.ffmpeg == nil
    }

    private var helperProblem: String? {
        switch model.python {
        case .needsSetup?: "The Python helper isn't set up, so models that need it can't run."
        case .missing?: "The Python helper is missing, so models that need it can't run."
        default: nil
        }
    }

    private var helperProblemTone: Tone {
        if case .missing? = model.python { return .danger }
        return .warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            if ffmpegPathMissing {
                AttentionLine("There's no ffmpeg at the location you chose.") {
                    Button("Choose…") { FFmpegInstall.choose(into: settings) }.buttonStyle(.secondary).controlSize(.small)
                    Button("Automatic") { settings.ffmpegPath = nil }.buttonStyle(.ghost).controlSize(.small)
                }
            }
            if let helperProblem {
                AttentionLine(helperProblem, tone: helperProblemTone) {
                    if !expanded {
                        Button("Details") { withStageAnimation(Theme.Motion.standard) { expanded = true } }
                            .buttonStyle(.ghost).controlSize(.small)
                    }
                }
            }
            AdvancedDisclosure("Advanced", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    FFmpegGroup(model: model)
                    PythonGroup(model: model)
                    SettingsSection(title: "Hugging Face token") {
                        Text("Stored in your Keychain and in \(HubTokenFile.path), where the hf command-line tool and Encore's Python helper read it.")
                            .textRole(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, Theme.Space.s)
        .padding(.bottom, SettingsSection<EmptyView>.gap)
    }
}

private struct FFmpegGroup: View {
    let model: SettingsModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SettingsSection(title: "ffmpeg", subtitle: "Used for MP3 export and for MKV, WebM and Ogg files.", divided: false) {
            if let url = model.ffmpeg {
                HStack(spacing: Theme.Space.s) {
                    StatusBadge("Found", tone: .success)
                    if settings.ffmpegPath == nil {
                        Text((url.path as NSString).abbreviatingWithTildeInPath).textRole(.mono, color: .textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Show ffmpeg in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.icon).labelStyle(.iconOnly).controlSize(.small)
                        .help("Show in Finder")
                }
            } else if model.ffmpegChecked {
                HStack(spacing: Theme.Space.s) {
                    StatusBadge("Not found", tone: .warning)
                    Text("Everything else works without it. Install it with Homebrew and Encore finds it.")
                        .textRole(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Theme.Space.s)
                }
                ShellCommandRow(command: FFmpegInstall.command)
            }
            HStack(spacing: Theme.Space.s) {
                Text("Location").textRole(.label, color: .textSecondary)
                Spacer()
                Text(settings.ffmpegPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Automatic")
                    .textRole(settings.ffmpegPath == nil ? .label : .mono,
                              color: settings.ffmpegPath == nil ? .textTertiary : .textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { FFmpegInstall.choose(into: settings) }.buttonStyle(.secondary).controlSize(.small)
                if settings.ffmpegPath != nil {
                    Button("Automatic") { settings.ffmpegPath = nil }.buttonStyle(.ghost).controlSize(.small)
                }
            }
        }
    }
}

private struct PythonGroup: View {
    let model: SettingsModel

    var body: some View {
        SettingsSection(title: "Python helper",
                        subtitle: "Runs the models that work better in Python, or only there, in a separate process. Starts on first use and stops after five idle minutes.") {
            switch model.python {
            case .found(let runtime)?:
                HStack(spacing: Theme.Space.s) {
                    StatusBadge(model.helper == nil ? "Ready" : "Running", tone: .success)
                    Text(origin(runtime.origin)).textRole(.caption)
                    Spacer()
                }
                if let h = model.helper {
                    VStack(spacing: 0) {
                        KeyValueRow("Helper", value: h.helperVersion)
                        KeyValueRow("Python", value: h.pythonVersion)
                        if let mlx = h.mlxAudioVersion { KeyValueRow("mlx-audio", value: mlx) }
                    }
                }
            case .needsSetup(let message)?:
                StatusBadge("Not set up", tone: .warning)
                Text(message).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                ShellCommandRow(command: "scripts/setup-python-runtime.sh")
            case .missing(let message)?:
                StatusBadge("Missing", tone: .danger)
                Text(message).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            case nil:
                Text("Checking…").textRole(.caption)
            }
        }
    }

    private func origin(_ o: PythonRuntime.Origin) -> String {
        switch o {
        case .bundled: "Bundled with Encore"
        case .development: "Development runtime in the repository"
        case .override: "From ENCORE_PYTHON_HOME"
        }
    }
}

/// A one-line shell command with a copy button.
private struct ShellCommandRow: View {
    let command: String
    var body: some View {
        HStack {
            Text(command).textRole(.mono, color: .textPrimary).textSelection(.enabled)
            Spacer()
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.icon).labelStyle(.iconOnly).controlSize(.small)
            .help("Copy")
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 32)
        .surface(.sunken, radius: Theme.Radius.s)
    }
}

// MARK: - About

private struct AboutSection: View {
    @State private var showsCredits = false

    var body: some View {
        SettingsSection(title: "About", subtitle: "Free and open source under the MIT license.") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("Encore").textRole(.headline)
                Text(version).textRole(.mono, color: .textTertiary)
                Spacer()
                Button("Credits…") { showsCredits = true }
                    .buttonStyle(.secondary).controlSize(.small)
            }
        }
        .stageSheet(isPresented: $showsCredits) { CreditsSheet() }
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// The libraries Encore is built with and the people behind the models.
struct CreditsSheet: View {
    @Environment(EncoreService.self) private var service
    @Environment(\.dismiss) private var dismiss

    private static let components: [(String, String, String)] = [
        ("MLX Swift", "Apple", "MIT"),
        ("mlx-audio-swift", "mlx-audio contributors", "MIT"),
        ("mlx-audio", "mlx-audio contributors", "MIT"),
        ("swift-transformers", "Hugging Face", "Apache-2.0"),
        ("swift-huggingface", "Hugging Face", "Apache-2.0"),
        ("huggingface_hub", "Hugging Face", "Apache-2.0"),
        ("GRDB.swift", "Gwendal Roué", "MIT"),
        ("Python", "Python Software Foundation", "PSF-2.0"),
        ("python-build-standalone", "Astral", "BSD-3-Clause"),
    ]

    var body: some View {
        SheetContainer(title: "Credits", subtitle: "Everything runs on this Mac. Each model has its own license, shown in its details on the Models screen.",
                       width: 520) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Built with").textRole(.section).padding(.bottom, Theme.Space.xs)
                        ForEach(Self.components, id: \.0) { name, author, license in
                            creditRow(name, author, license)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Models by").textRole(.section).padding(.bottom, Theme.Space.xs)
                        ForEach(service.catalog.credits) { c in
                            creditRow(c.family, ListFormatter.localizedString(byJoining: c.authors), c.licenses.joined(separator: ", "))
                        }
                        let publishers = service.catalog.weightPublishers
                        if !publishers.isEmpty {
                            Text("Weights downloaded from \(ListFormatter.localizedString(byJoining: publishers)) on Hugging Face.")
                                .textRole(.caption, color: .textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, Theme.Space.xs)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 380)
        } actions: {
            Button("Done") { dismiss() }
                .buttonStyle(.secondary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func creditRow(_ name: String, _ author: String, _ license: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(name).textRole(.label, color: .textPrimary)
            Text(author).textRole(.caption, color: .textTertiary).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(license).textRole(.monoSmall, color: .textSecondary)
        }
        .padding(.vertical, 5)
    }
}
