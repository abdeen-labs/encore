import EncoreCore
import SwiftUI

/// The custom navigation rail: grouped sections, the selected pill, and (while anything runs) the
/// activity card at its foot.
struct SidebarRail: View {
    @Environment(Router.self) private var router
    @Environment(RuntimeStatus.self) private var status
    @Environment(\.forcesShortcutHints) private var forcesHints
    @Environment(\.hidesDebugChrome) private var hidesDebugChrome
    @Environment(\.isSnapshotting) private var isSnapshotting
    @Namespace private var spotlight
    @State private var hints = ShortcutHintMonitor()
    static let width: CGFloat = 212

    private var showsHints: Bool { forcesHints || hints.isShowing }

    var body: some View {
        // A short window with a job running: the tight layout lets the activity card fit without pushing anything off.
        ViewThatFits(in: .vertical) {
            rail(tight: false)
            rail(tight: true)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .stageAnimation(Theme.Motion.quick, value: showsHints)
        .onAppear { if !isSnapshotting { hints.start() } }
        .onDisappear { hints.stop() }
    }

    private func rail(tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: tight ? 12 : 22) {
                ForEach(AppSection.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.rawValue)
                            .textRole(.eyebrow)
                            .padding(.leading, 24)
                            .padding(.bottom, 4)
                        ForEach(AppSection.allCases.filter { $0.group == group }) { section in
                            RailItem(title: section.title, symbol: section.symbol,
                                     shortcut: section.shortcutNumber.map { "⌘\($0)" } ?? "⌘,",
                                     key: section.shortcutNumber.map(String.init) ?? ",", showsKey: showsHints,
                                     isSelected: !router.isShowingGallery && router.section == section,
                                     spotlight: spotlight) {
                                router.go(section)
                            }
                        }
                    }
                }
            }
            // Clears the window's traffic lights, which sit over the top of the rail.
            .padding(.top, tight ? 48 : 58)

            Spacer(minLength: Theme.Space.m)

            RailActivity(compact: tight)
                .padding(.horizontal, 14)
                .padding(.bottom, tight ? Theme.Space.s : Theme.Space.m)
                .stageAnimation(Theme.Motion.standard, value: status.isBusy)

            #if DEBUG
            // The gallery steps aside for the activity card when the window is too short for both (⇧⌘G still opens it).
            if !(tight && status.isBusy), !hidesDebugChrome {
                RailItem(title: "Gallery", symbol: "square.grid.2x2", shortcut: "⇧⌘G", key: "⇧G", showsKey: showsHints,
                         isSelected: router.isShowingGallery, spotlight: spotlight) {
                    router.showGallery()
                }
                .padding(.bottom, Theme.Space.l)
            }
            #endif
        }
    }
}

private struct RailItem: View {
    let title: String
    let symbol: String
    let shortcut: String
    /// The key pressed with Command, shown as a keycap while Command is held.
    let key: String
    let showsKey: Bool
    let isSelected: Bool
    let spotlight: Namespace.ID
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(isSelected ? Color.onTangerine : (isHovered ? .textPrimary : .textSecondary))
                    .background {
                        if isSelected {
                            Circle().fill(LinearGradient(colors: [Color.tangerineLight, .tangerine], startPoint: .top, endPoint: .bottom))
                        }
                    }
                    .rotationEffect(.degrees(isSelected ? -8 : 0))
                    .scaleEffect(isHovered && !isSelected ? 1.1 : 1)
                Text(title)
                    .textRole(isSelected ? .headline : .body,
                              color: isSelected || isHovered ? .textPrimary : .textSecondary)
                Spacer(minLength: 0)
                // Both live in the row's fixed height, so neither shifts the rail.
                if showsKey {
                    KeycapBadge(key).transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85)))
                } else if isHovered && !isSelected {
                    Text(shortcut).textRole(.monoSmall, color: .textTertiary)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 34)
            .background {
                if isSelected {
                    // The selected pill: white, floating on the cream.
                    Capsule()
                        .fill(Color.surfaceRaised)
                        .overlay(Capsule().inset(by: 0.5).stroke(Color.hairline, lineWidth: 1))
                        .lift()
                        .matchedGeometryEffect(id: "spot", in: spotlight)
                } else if isHovered {
                    Capsule().fill(Color.textPrimary.opacity(0.05))
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(title)  \(shortcut)")
    }
}
