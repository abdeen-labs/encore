import EncoreCore
import Foundation
import Observation

/// Runs the local API (and the MCP server under it) while Settings → Local API is on, on the port chosen there.
/// Snapshots and isolated runs never open a port.
@MainActor @Observable
final class LocalAPIController {
    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var status: Status = .off

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let api: LocalAPI
    @ObservationIgnored private let isLive: Bool
    @ObservationIgnored private var server: LocalHTTPServer?
    @ObservationIgnored private var serverPort: Int?

    init(service: EncoreService, settings: AppSettings, isLive: Bool) {
        self.settings = settings
        self.isLive = isLive
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        api = LocalAPI(service: service, version: version) { url, title in await APIPlayback.play(url, title: title) }
        if isLive { apply(); observeSettings() }
    }

    /// The base URL clients use.
    var baseURL: String { "http://127.0.0.1:\(settings.localAPIPort)" }
    var mcpURL: String { baseURL + "/mcp" }
    var claudeCodeCommand: String { "claude mcp add --transport http encore \(mcpURL)" }

    /// Starts, stops or moves the server to match the settings.
    func apply() {
        let wanted = isLive && settings.localAPIEnabled
        let port = settings.localAPIPort
        if wanted, server != nil, serverPort == port, status != .off { return }
        server?.stop()
        server = nil
        serverPort = nil
        guard wanted else { status = .off; return }
        status = .starting
        let api = self.api
        let s = LocalHTTPServer(port: port) { await api.handle($0) }
        server = s
        serverPort = port
        Task {
            do {
                try await s.start()
                if self.server === s { self.status = .running(port: port) } else { s.stop() }
            } catch {
                guard self.server === s else { return }
                self.server = nil
                self.serverPort = nil
                self.status = .failed(error.localizedDescription)
            }
        }
    }

    /// Tries again after a failure (say, once the other app let go of the port).
    func retry() {
        server?.stop()
        server = nil
        serverPort = nil
        apply()
    }

    #if DEBUG
    /// Snapshots: show a status without listening.
    func showFixture(_ status: Status) { self.status = status }
    #endif

    private func observeSettings() {
        withObservationTracking {
            _ = settings.localAPIEnabled
            _ = settings.localAPIPort
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.apply()
                self.observeSettings()
            }
        }
    }
}
