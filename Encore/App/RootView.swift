import SwiftUI

/// The window layout: the rail on the ink, the current screen on a lit "stage" panel, and the
/// player dock in the pit underneath it.
struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(ToastCenter.self) private var toasts

    var body: some View {
        HStack(spacing: 0) {
            SidebarRail()
            VStack(spacing: 0) {
                StagePanel {
                    currentScreen
                        .id(router.isShowingGallery ? "gallery" : router.section.rawValue)
                        .transition(.opacity)
                }
                .toastOverlay(toasts)
                PlayerDock()
            }
            .padding(.top, Theme.Space.s)
            .padding(.trailing, Theme.Space.s)
        }
        .background(StageBackdrop())
        .preferredColorScheme(.dark)
        .tint(.tungsten)
    }

    @ViewBuilder private var currentScreen: some View {
        #if DEBUG
        if router.isShowingGallery {
            ComponentGallery()
        } else {
            SectionScreen(section: router.section)
        }
        #else
        SectionScreen(section: router.section)
        #endif
    }
}

/// Maps a section to its screen.
struct SectionScreen: View {
    let section: AppSection

    var body: some View {
        switch section {
        case .studio: StudioScreen()
        case .clone: CloneScreen()
        case .voices: VoicesScreen()
        case .design: DesignScreen()
        case .changer: ChangerScreen()
        case .conversations: ConversationsScreen()
        case .transcribe: TranscribeScreen()
        case .history: HistoryScreen()
        case .models: ModelsScreen()
        case .settings: SettingsScreen()
        }
    }
}

/// The proscenium: a rounded, faintly lit panel the screens play on.
struct StagePanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.l, style: .continuous)
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                shape.fill(Color.stage)
                    .overlay {
                        // House lights: a warm wash from above, falling off quickly.
                        shape.fill(RadialGradient(colors: [Color(hex: 0xFFB648, opacity: 0.07), .clear],
                                                  center: .init(x: 0.5, y: -0.05), startRadius: 0, endRadius: 520))
                    }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.hairline, lineWidth: 1))
    }
}
