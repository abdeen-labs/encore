import EncoreCore
import SwiftUI

/// Which gate to get through, for which download.
struct GateRequest: Identifiable, Equatable {
    var modelID: String
    var variantID: String
    var repo: String
    var id: String { "\(modelID)/\(variantID)/\(repo)" }
}

/// The gated-model flow: explain the gate in plain words, open the model's Hugging Face page in an
/// in-app browser so the user can accept, watch for access, and retry the download once it's granted.
struct GateFlowView: View {
    let request: GateRequest
    let manifest: ModelManifest
    let library: ModelsLibrary
    var startsInBrowser = false

    @Environment(ModelDownloadCenter.self) private var downloads
    @Environment(HubAccountModel.self) private var account
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var page: HubWebPage?
    @State private var granted = false

    private var variant: ModelVariant { manifest.variant(request.variantID) }
    private var hub: HubService { downloads.service }
    private var gate: ModelsLibrary.GateState { library.gates[request.repo] ?? .unknown }
    private var info: HubRepoInfo? { library.repoInfo[request.repo] }

    var body: some View {
        Group {
            if let page {
                browser(page)
            } else {
                explanation
            }
        }
        .task {
            if account.status == .unknown { await account.refresh() }
            if info == nil, !library.isFixture { library.repoInfo[request.repo] = try? await hub.repoInfo(request.repo) }
            if startsInBrowser { open() }
        }
    }

    // MARK: Explanation

    private var hasToken: Bool {
        switch account.status {
        case .signedIn, .unreachable, .checking: true
        default: account.tokenSource != nil
        }
    }

    private var explanation: some View {
        SheetContainer(title: "Accept the terms for \(manifest.name)", subtitle: request.repo, width: 560) {
            Text(intro).textRole(.body).fixedSize(horizontal: false, vertical: true)

            if let prompt = info?.gatePrompt {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What the authors ask").textRole(.section)
                    ScrollView {
                        Text(prompt).textRole(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                    }
                    .frame(maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                    .surface(.sunken, radius: Theme.Radius.m)
                }
            }

            KeyValueRow("License") {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(manifest.license.name).textRole(.body)
                    if manifest.isNonCommercial { Chip("Non-commercial", tone: .warning) }
                    if let link = info?.licenseLink ?? manifest.license.url.flatMap(URL.init(string:)) {
                        LinkButton(title: "Read", url: link)
                    }
                }
            }
            if let summary = manifest.license.summary {
                Text(summary).textRole(.caption).fixedSize(horizontal: false, vertical: true)
            }

            statusBanner
        } actions: {
            Button("Not now") { dismiss() }.buttonStyle(.ghost)
            if !hasToken || gate == .invalidToken {
                Button("Open Settings", systemImage: "key") {
                    dismiss()
                    router.go(.settings)
                }
                .buttonStyle(.primary)
            } else {
                Button("Open Hugging Face page", systemImage: "safari") { open() }
                    .buttonStyle(.primary)
            }
        }
    }

    private var intro: String {
        let kind = info?.gate ?? {
            if case .gated(let k, _) = gate { return k }
            return .auto
        }()
        let how = kind == .manual
            ? "The authors review each request themselves, so access can take a while after you ask."
            : "It's free, and access is granted the moment you accept."
        return "The authors of \(request.repo) ask everyone to accept their conditions on Hugging Face before downloading. \(how) Encore watches for access and starts the download as soon as it's granted."
    }

    @ViewBuilder private var statusBanner: some View {
        if !hasToken {
            Banner(.warning, title: "Add a Hugging Face token first",
                   message: "Accepting a gate is tied to your Hugging Face account, so Encore needs a token from that account to download. Create a read token on huggingface.co and add it in Settings, then come back here.")
        } else if gate == .invalidToken {
            Banner(.danger, title: "Your Hugging Face token was rejected", message: "Replace it in Settings, then try again.")
        } else if case .pending(let message) = gate {
            Banner(.neutral, title: "Request sent — waiting for the authors", message: message)
        } else if case .open = gate {
            Banner(.success, title: "Access granted", message: "You can download \(manifest.name) now.")
        }
    }

    // MARK: Browser

    private func open() {
        page = HubWebPage(url: hub.modelPageURL(request.repo))
    }

    private func browser(_ page: HubWebPage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.s) {
                Button("Back", systemImage: "chevron.left") { page.goBack() }
                    .buttonStyle(.icon).labelStyle(.iconOnly).disabled(!page.canGoBack)
                Button("Reload", systemImage: "arrow.clockwise") { page.reload() }
                    .buttonStyle(.icon).labelStyle(.iconOnly)
                HStack(spacing: 6) {
                    Image(systemName: page.isSecure ? "lock.fill" : "lock.open")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(page.isSecure ? Color.textTertiary : .velvetText)
                    Text(page.host).textRole(.mono, color: .textSecondary).lineLimit(1)
                    if page.isLoading { ActivityIndicator(size: 11) }
                }
                .padding(.horizontal, Theme.Space.m)
                .frame(height: Theme.ControlHeight.small)
                .surface(.sunken, radius: Theme.Radius.s)
                .help(page.url.absoluteString)
                Spacer(minLength: Theme.Space.s)
                accessPill
                Button("Open in browser", systemImage: "arrow.up.forward.app") { page.openInBrowser() }
                    .buttonStyle(.icon).labelStyle(.iconOnly)
                Button("Done") { finish() }
                    .buttonStyle(.secondary)
            }
            .controlSize(.small)
            .padding(.horizontal, Theme.Space.l)
            .padding(.vertical, Theme.Space.s + 2)
            .background(Color.surface)
            Hairline()
            ZStack {
                HubWebView(page: page)
                if let popup = page.popup {
                    Color.black.opacity(0.45)
                    VStack(spacing: 0) {
                        HStack {
                            Text("Sign-in window").textRole(.label, color: .textSecondary)
                            Spacer()
                            Button("Close", systemImage: "xmark") { page.closePopup() }
                                .buttonStyle(.icon).labelStyle(.iconOnly).controlSize(.small)
                        }
                        .padding(.horizontal, Theme.Space.m)
                        .frame(height: 34)
                        .background(Color.surfaceRaised)
                        PopupWebView(web: popup)
                    }
                    .frame(width: 520, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.m))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.m).strokeBorder(Color.hairlineStrong))
                    .elevation()
                }
            }
        }
        .frame(width: 920, height: 620)
        .background(Color.surface)
        .task(id: request.repo) { await watchAccess() }
    }

    @ViewBuilder private var accessPill: some View {
        switch gate {
        case .open: StatusBadge(granted ? "Access granted" : "Access open", tone: .success)
        case .pending: StatusBadge("Waiting for approval", pulsing: true)
        case .invalidToken: StatusBadge("Token rejected", tone: .danger)
        default: StatusBadge("Waiting for you to accept", tone: .warning, pulsing: true)
        }
    }

    /// Polls access every few seconds while the page is open; once granted, closes and retries the download.
    private func watchAccess() async {
        guard !library.isFixture else { return }
        while !Task.isCancelled {
            if await library.checkAccess(request.repo, hub: hub) == .open {
                granted = true
                try? await Task.sleep(for: .milliseconds(900))
                retryAndClose()
                return
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func finish() {
        if gate == .open { retryAndClose(); return }
        // Keep watching for a while after the sheet closes (a manual approval, or an accept that hasn't registered yet).
        let manifest = manifest, variant = variant, downloads = downloads
        library.pollAfterGate(repo: request.repo, hub: hub) { downloads.retry(manifest, variant) }
        dismiss()
    }

    private func retryAndClose() {
        library.stopPolling(request.repo)
        downloads.retry(manifest, variant)
        dismiss()
    }
}
