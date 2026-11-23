import AppKit
import EncoreCore
import SwiftUI

/// Settings → Local API: one switch, and while it's on, where to reach it and how to add Encore to Claude Code.
struct LocalAPISection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LocalAPIController.self) private var controller
    @State private var portText = ""

    var body: some View {
        @Bindable var settings = settings
        SettingsSection(title: "Local API",
                        subtitle: "Lets scripts and AI agents on this Mac make speech and transcripts while Encore is open. Nothing outside this Mac can connect.") {
            Toggle("Turn on the local API", isOn: $settings.localAPIEnabled).toggleStyle(.stage)
            if settings.localAPIEnabled {
                status
                HStack(spacing: Theme.Space.m) {
                    Text("Port").textRole(.label, color: .textSecondary)
                    Spacer()
                    StageTextField(String(AppSettings.Values.defaultLocalAPIPort), text: $portText, onSubmit: commitPort)
                        .frame(width: 96)
                        .help("Press Return to use a new port, from 1024 to 65535.")
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Add Encore to Claude Code:").textRole(.caption)
                    ShellCommandRow(command: controller.claudeCodeCommand)
                }
                Text("Other apps can use \(controller.baseURL)/v1 like OpenAI's speech and transcription API, or \(controller.mcpURL) as an MCP server. Takes they make show up in History.")
                    .textRole(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { portText = String(settings.localAPIPort) }
        .onChange(of: settings.localAPIPort) { portText = String(settings.localAPIPort) }
    }

    @ViewBuilder private var status: some View {
        switch controller.status {
        case .running:
            HStack(spacing: Theme.Space.s) {
                StatusBadge("Running", tone: .success)
                Text(controller.baseURL).textRole(.mono, color: .textSecondary).textSelection(.enabled)
                Spacer()
                Button("Copy address", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(controller.baseURL, forType: .string)
                }
                .buttonStyle(.icon).labelStyle(.iconOnly).controlSize(.small)
                .help("Copy address")
            }
        case .starting:
            StatusBadge("Starting", tone: .neutral)
        case .failed(let message):
            AttentionLine(message) {
                Button("Try again") { controller.retry() }.buttonStyle(.secondary).controlSize(.small)
            }
        case .off:
            EmptyView()
        }
    }

    private func commitPort() {
        let trimmed = portText.trimmingCharacters(in: .whitespaces)
        if let port = Int(trimmed), (1024...65535).contains(port) {
            settings.localAPIPort = port
        }
        portText = String(settings.localAPIPort)
    }
}
