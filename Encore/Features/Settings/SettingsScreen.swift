import AppKit
import EncoreCore
import SwiftUI
import UniformTypeIdentifiers

/// Preferences, in sections: Hugging Face, memory, output, pronunciations, ffmpeg, the Python helper, storage, about,
/// and the two reset actions at the very bottom.
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
            HuggingFaceSection()
            MemorySection()
            OutputSection(ffmpegFound: model.ffmpeg != nil || !model.ffmpegChecked)
            PronunciationsSection()
            FFmpegSection(model: model)
            PythonSection(model: model)
            StorageSection(model: model)
            AboutSection()
            ResetSection(onReset: refreshStorage)
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

/// A settings section: title and one-line purpose on the left rail of the card, controls on the right.
struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    var accent: Color = .tungsten
    @ViewBuilder var content: Content

    init(title: String, subtitle: String, symbol: String, accent: Color = .tungsten, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.accent = accent; self.content = content()
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.xl) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(accent.opacity(0.1)))
                    Text(title).textRole(.heading)
                    Text(subtitle).textRole(.caption).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 168, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.m) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
        SettingsSection(title: "Hugging Face", subtitle: "Needed for gated models; speeds up every download.", symbol: "key") {
            switch account.status {
            case .signedIn(let a):
                signedIn(a)
            case .checking:
                HStack(spacing: Theme.Space.s) {
                    ActivityIndicator(size: 14)
                    Text("Checking your token with Hugging Face…").textRole(.caption)
                }
            case .invalidToken:
                Banner(.danger, title: "Hugging Face rejected the saved token",
                       message: "It may have been revoked or expired. Paste a new one, or sign out.")
                tokenEntry(prompt: "Paste a new token")
                signOutRow
            case .unreachable(let message):
                Banner(.warning, title: "Couldn't reach Hugging Face",
                       message: "Your token is kept; Encore will check it again later. \(message)") {
                    Button("Try again") { Task { await account.refresh() } }.buttonStyle(.secondary).controlSize(.small)
                }
                signOutRow
            case .signedOut, .unknown:
                if account.isSignedOutOfEncoreOnly { encoreOnlyNotice }
                Text("Paste an access token from your Hugging Face account. A read token is enough.")
                    .textRole(.body).fixedSize(horizontal: false, vertical: true)
                tokenEntry(prompt: "hf_…")
            }
            if let source = account.tokenSource, source == .environment {
                Text("Using HF_TOKEN from the environment, which takes precedence over the saved token.")
                    .textRole(.caption, color: .textTertiary)
            }
            Text("Stored in your Keychain and in \(Self.tokenPath), where the hf command-line tool and Encore's Python helper read it.")
                .textRole(.caption, color: .textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .stageSheet(isPresented: $confirmingSignOut) {
            SignOutSheet(tokenPath: Self.tokenPath, everywhere: signOutEverywhere, encoreOnly: signOutOfEncoreOnly)
        }
    }

    /// Shown while signed out of Encore only, when the shared token file may still hold a token.
    private var encoreOnlyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(account.sharedTokenFileExists
                 ? "Signed out of Encore only. The token in \(Self.tokenPath) is still there for the hf tool; Encore ignores it until you sign in here."
                 : "Signed out of Encore only. Encore won't use \(Self.tokenPath) until you sign in here.")
                .textRole(.caption, color: .textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Space.s)
            if account.sharedTokenFileExists {
                Button("Use that token") { Task { await account.useSharedToken() } }
                    .buttonStyle(.secondary).controlSize(.small)
                    .fixedSize()
            }
        }
    }

    static var tokenPath: String {
        (EncorePaths.huggingFaceTokenFile.path as NSString).abbreviatingWithTildeInPath
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
                if let role = a.tokenRole { Chip(roleLabel(role), symbol: "key") }
            }
            if replacing {
                tokenEntry(prompt: "Paste the new token")
            } else {
                HStack(spacing: Theme.Space.s) {
                    Button("Replace token") { replacing = true }.buttonStyle(.secondary).controlSize(.small)
                    signOutButton
                    Spacer()
                    LinkButton(title: "Manage tokens", url: Self.tokensURL)
                }
            }
        }
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "read": "Read token"
        case "write": "Write token"
        case "fineGrained": "Fine-grained token"
        default: role.capitalized + " token"
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
                    Text(account.status == .invalidToken ? "That token was rejected — nothing was saved."
                                                         : "Couldn't check that token — nothing was saved.")
                        .textRole(.caption, color: .velvet)
                }
                Spacer()
                LinkButton(title: "Create a token on huggingface.co", url: Self.tokensURL)
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

    private var signOutRow: some View {
        HStack { signOutButton; Spacer() }
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
                .foregroundStyle(focused ? Color.tungsten : .textTertiary)
            SecureField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Color.textTertiary))
                .textFieldStyle(.plain)
                .font(.mono(12.5))
                .foregroundStyle(.textPrimary)
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
            Circle().fill(Color.tungsten.opacity(0.14))
            Text(String((account.fullName ?? account.name).prefix(1)).uppercased())
                .font(.display(19)).foregroundStyle(.tungsten)
            if let url = account.avatarURL, !isSnapshotting {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: 40, height: 40)
        .overlay(Circle().strokeBorder(Color.hairlineStrong))
    }
}

// MARK: - Memory

private struct MemorySection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RuntimeStatus.self) private var status

    private static let choices = [5, 10, 15, 30, 60, 0]

    var body: some View {
        @Bindable var settings = settings
        SettingsSection(title: "Memory", subtitle: "Models stay loaded while you work and leave when idle.", symbol: "memorychip") {
            HStack(alignment: .center, spacing: Theme.Space.m) {
                Text("Unload idle models after").textRole(.label, color: .textSecondary)
                Spacer()
                MenuPicker(selection: $settings.idleUnloadMinutes,
                           options: Self.choices.contains(settings.idleUnloadMinutes) ? Self.choices : Self.choices + [settings.idleUnloadMinutes]) {
                    $0 == 0 ? "Never" : ($0 >= 60 ? "\($0 / 60) hour" : "\($0) minutes")
                }
                .frame(width: 150)
            }
            KeyValueRow("This Mac") {
                Text("\(Bytes.memory(status.memory.physicalBytes)) of memory")
                    .textRole(.mono, color: .textSecondary)
            }
            Text("Before loading a model that won't fit comfortably, Encore says so and unloads idle models first.")
                .textRole(.caption, color: .textTertiary)
            LoadedModelsStrip(showsDiskUsage: false)
        }
    }
}

// MARK: - Output

private struct OutputSection: View {
    let ffmpegFound: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        SettingsSection(title: "Output", subtitle: "Defaults for new takes and exports.", symbol: "waveform") {
            HStack(spacing: Theme.Space.m) {
                Text("Export format").textRole(.label, color: .textSecondary)
                Spacer()
                SegmentedControl(selection: $settings.defaultExportFormat, options: AppSettings.ExportFormat.allCases) {
                    $0.rawValue.uppercased()
                }
                .fixedSize()
            }
            if settings.defaultExportFormat == .mp3 && !ffmpegFound {
                Text("MP3 needs ffmpeg, which isn't installed — see below.").textRole(.caption, color: .tungsten)
            }
            PerforatedDivider(bleed: 0)
            Toggle("Normalize loudness", isOn: $settings.postProcessing.normalizeLoudness).toggleStyle(.stage)
            if settings.postProcessing.normalizeLoudness {
                StageSlider("Target loudness", value: $settings.postProcessing.targetLUFS, in: -24 ... -9, step: 1,
                            defaultValue: -16) { String(format: "%.0f LUFS", $0) }
            }
            Toggle("Trim silences", isOn: $settings.postProcessing.removeSilence).toggleStyle(.stage)
            if settings.postProcessing.removeSilence {
                StageSlider("Longest pause kept", value: $settings.postProcessing.maxSilenceSeconds, in: 0.2...2, step: 0.05,
                            defaultValue: 0.6) { String(format: "%.2f s", $0) }
            }
            Text("−16 LUFS suits podcasts and voice-over; −14 is louder, for streaming platforms.")
                .textRole(.caption, color: .textTertiary)
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
        SettingsSection(title: "Pronunciations", subtitle: "Words every voice should say differently.", symbol: "character.book.closed") {
            HStack(spacing: Theme.Space.m) {
                Text(store.entries.isEmpty ? "No pronunciations yet"
                     : "\(store.entries.count) \(store.entries.count == 1 ? "entry" : "entries"), \(enabled) on")
                    .textRole(.label, color: .textSecondary)
                Spacer()
                Button("Edit pronunciations…", systemImage: "character.book.closed") { showEditor = true }
                    .buttonStyle(.secondary).controlSize(.small)
            }
            Text("Applied to speech and conversations before the model reads the text: names, jargon, acronyms.")
                .textRole(.caption, color: .textTertiary)
        }
        .pronunciationSheet(isPresented: $showEditor)
    }
}

// MARK: - ffmpeg

private struct FFmpegSection: View {
    let model: SettingsModel
    @Environment(AppSettings.self) private var settings

    var body: some View {
        SettingsSection(title: "ffmpeg", subtitle: "Used for MP3 export and for MKV, WebM and Ogg files.", symbol: "film") {
            if let url = model.ffmpeg {
                HStack(spacing: Theme.Space.s) {
                    StatusBadge("Found", tone: .success)
                    Text((url.path as NSString).abbreviatingWithTildeInPath).textRole(.mono, color: .textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Show", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.ghost).controlSize(.small)
                }
            } else if model.ffmpegChecked {
                Banner(.warning, title: settings.ffmpegPath == nil ? "ffmpeg isn't installed" : "No ffmpeg at the chosen path",
                       message: "Everything else works without it. With Homebrew: brew install ffmpeg — Encore finds it on its own.") {
                    Button("Copy command", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
                    }
                    .buttonStyle(.secondary).controlSize(.small)
                }
            }
            HStack(spacing: Theme.Space.s) {
                Text("Location").textRole(.label, color: .textSecondary)
                Spacer()
                Text(settings.ffmpegPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Automatic")
                    .textRole(.mono, color: settings.ffmpegPath == nil ? .textTertiary : .textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                Button("Choose…") { choose() }.buttonStyle(.secondary).controlSize(.small)
                if settings.ffmpegPath != nil {
                    Button("Automatic") { settings.ffmpegPath = nil }.buttonStyle(.ghost).controlSize(.small)
                }
            }
        }
    }

    private func choose() {
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

// MARK: - Python helper

private struct PythonSection: View {
    let model: SettingsModel

    var body: some View {
        SettingsSection(title: "Python helper", subtitle: "Runs the models Swift can't yet, in a separate process.", symbol: "shippingbox") {
            switch model.python {
            case .found(let runtime)?:
                HStack(spacing: Theme.Space.s) {
                    StatusBadge(model.helper == nil ? "Ready" : "Running", tone: .success)
                    Text(origin(runtime.origin)).textRole(.caption)
                    Spacer()
                }
                if let h = model.helper {
                    KeyValueRow("Helper", value: h.helperVersion)
                    KeyValueRow("Python", value: h.pythonVersion)
                    if let mlx = h.mlxAudioVersion { KeyValueRow("mlx-audio", value: mlx) }
                } else {
                    Text("Starts on first use and stops after five idle minutes.").textRole(.caption, color: .textTertiary)
                }
            case .needsSetup(let message)?:
                Banner(.warning, title: "Not set up", message: message)
                ShellCommandRow(command: "Scripts/setup-python-runtime.sh")
            case .missing(let message)?:
                Banner(.danger, title: "Missing", message: message)
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
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 32)
        .surface(.sunken, radius: Theme.Radius.s)
    }
}

// MARK: - Storage

private struct StorageSection: View {
    let model: SettingsModel

    var body: some View {
        SettingsSection(title: "Storage", subtitle: "Where Encore keeps things on this Mac.", symbol: "internaldrive") {
            if model.storage.isEmpty {
                Text("Measuring…").textRole(.caption)
            }
            VStack(spacing: 0) {
                ForEach(Array(model.storage.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { HLine().stroke(Color.hairline).frame(height: 1) }
                    HStack(spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.ui(13, weight: .semibold)).foregroundStyle(.textPrimary)
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
                    }
                    .padding(.vertical, Theme.Space.s)
                }
            }
        }
    }
}

// MARK: - About

private struct AboutSection: View {
    @Environment(EncoreService.self) private var service

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
        SettingsSection(title: "About", subtitle: "Free and open source under the MIT license. Everything runs on this Mac.", symbol: "theatermasks") {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text("Encore").textRole(.headline)
                Text(version).textRole(.mono, color: .textTertiary)
            }
            Text("Each model has its own license, shown in its details on the Models screen.")
                .textRole(.caption)
            VStack(alignment: .leading, spacing: 0) {
                Text("Built with").textRole(.eyebrow).padding(.bottom, Theme.Space.xs)
                ForEach(Self.components, id: \.0) { name, author, license in
                    creditRow(name, author, license)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Models by").textRole(.eyebrow).padding(.bottom, Theme.Space.xs)
                ForEach(service.catalog.credits) { c in
                    creditRow(c.family, ListFormatter.localizedString(byJoining: c.authors), c.licenses.joined(separator: ", "))
                }
                let publishers = service.catalog.weightPublishers
                if !publishers.isEmpty {
                    Text("Weights downloaded from \(ListFormatter.localizedString(byJoining: publishers)) on Hugging Face.")
                        .textRole(.caption, color: .textTertiary)
                        .padding(.top, Theme.Space.xs)
                }
            }
        }
    }

    private func creditRow(_ name: String, _ author: String, _ license: String) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(name).font(.ui(12.5, weight: .medium)).foregroundStyle(.textPrimary)
            Text(author).textRole(.caption, color: .textTertiary).lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(license).textRole(.monoSmall, color: .textSecondary)
        }
        .padding(.vertical, 5)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}
