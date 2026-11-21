import SwiftUI

/// The global mini-player slot, pinned under the stage on every screen.
///
/// PLACEHOLDER: the player feature replaces this type's body. Keep the type name; the shell
/// (`RootView`) places it full-width under the stage panel and lets it size its own height.
struct PlayerDock: View {
    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Button("Play", systemImage: "play.fill") {}
                .buttonStyle(.icon)
                .disabled(true)
            ProgressBar(value: 0, tone: .neutral, height: 3)
                .opacity(0.6)
            Text("Nothing on stage")
                .font(.ui(11.5, weight: .medium))
                .foregroundStyle(.textTertiary)
            Text("0:00")
                .font(.mono(11))
                .foregroundStyle(.textTertiary)
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Player")
    }
}
