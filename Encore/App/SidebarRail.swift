import EncoreCore
import SwiftUI

/// The custom navigation rail: wordmark, grouped sections, the lit selection, and (while anything runs) the
/// activity lamp at its foot.
struct SidebarRail: View {
    @Environment(Router.self) private var router
    @Environment(RuntimeStatus.self) private var status
    @Namespace private var spotlight
    static let width: CGFloat = 212

    var body: some View {
        // A short window with a job running: the tight layout lets the activity card fit without pushing anything off.
        ViewThatFits(in: .vertical) {
            rail(tight: false)
            rail(tight: true)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func rail(tight: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.top, tight ? 40 : 46)
                .padding(.leading, 22)
                .padding(.bottom, tight ? 16 : 26)

            VStack(alignment: .leading, spacing: tight ? 12 : 22) {
                ForEach(AppSection.Group.allCases, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.rawValue)
                            .textRole(.eyebrow)
                            .padding(.leading, 22)
                            .padding(.bottom, 6)
                        ForEach(AppSection.allCases.filter { $0.group == group }) { section in
                            RailItem(title: section.title, symbol: section.symbol,
                                     shortcut: section.shortcutNumber.map { "⌘\($0)" } ?? "⌘,",
                                     isSelected: !router.isShowingGallery && router.section == section,
                                     spotlight: spotlight) {
                                router.go(section)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: Theme.Space.m)

            RailActivity(compact: tight)
                .padding(.horizontal, 14)
                .padding(.bottom, tight ? Theme.Space.s : Theme.Space.m)
                .stageAnimation(Theme.Motion.standard, value: status.isBusy)

            #if DEBUG
            // The gallery steps aside for the activity card when the window is too short for both (⇧⌘G still opens it).
            if !(tight && status.isBusy) {
                RailItem(title: "Gallery", symbol: "square.grid.2x2", shortcut: "⇧⌘G",
                         isSelected: router.isShowingGallery, spotlight: spotlight) {
                    router.showGallery()
                }
                .padding(.bottom, Theme.Space.l)
            }
            #endif
        }
    }
}

/// "Encore" set in italic Bodoni, with a tungsten full stop like a lamp.
private struct Wordmark: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("Encore")
                .font(.display(30, italic: true))
                .foregroundStyle(.textPrimary)
            Circle()
                .fill(Color.tungsten)
                .frame(width: 5.5, height: 5.5)
                .glow(.tungsten, radius: 6, intensity: 0.8)
        }
        .accessibilityElement()
        .accessibilityLabel("Encore")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RailItem: View {
    let title: String
    let symbol: String
    let shortcut: String
    let isSelected: Bool
    let spotlight: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.tungsten : (isHovered ? .textPrimary : .textTertiary))
                Text(title)
                    .font(.ui(13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color(hex: 0xFFE3B8) : (isHovered ? .textPrimary : .textSecondary))
                Spacer(minLength: 0)
                if isHovered && !isSelected {
                    Text(shortcut).font(.mono(10)).foregroundStyle(.textTertiary)
                        .transition(.opacity)
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .frame(height: 30)
            .background(alignment: .leading) {
                if isSelected {
                    ZStack(alignment: .leading) {
                        // The beam: light spilling in from the left edge.
                        LinearGradient(colors: [Color.tungsten.opacity(0.16), Color.tungsten.opacity(0.04), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                        // The lamp itself.
                        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 2, topTrailingRadius: 2)
                            .fill(Color.tungsten)
                            .frame(width: 3)
                            .padding(.vertical, 6)
                            .glow(.tungsten, radius: 8, intensity: 0.9)
                    }
                    .matchedGeometryEffect(id: "spot", in: spotlight)
                } else if isHovered {
                    Color.textPrimary.opacity(0.03)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .stageAnimation(Theme.Motion.quick, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help("\(title)  \(shortcut)")
    }
}
