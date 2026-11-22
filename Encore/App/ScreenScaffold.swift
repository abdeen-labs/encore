import SwiftUI

extension EnvironmentValues {
    /// When false, `ScreenScaffold` lays its content out at full height without a scroll view.
    /// The snapshot renderer uses this for `-full` captures.
    @Entry var scaffoldScrolls: Bool = true
    /// Where a scrolling `ScreenScaffold` starts (fixtures use `.bottom` to show a screen's last section).
    @Entry var scaffoldScrollAnchor: UnitPoint? = nil
}

/// The standard screen frame: a one-row header (round display title, the tagline on its baseline, trailing
/// actions; about 70pt tall) above scrolling content. The tagline hides, whole, when there's no room for it
/// beside the actions.
///
///     ScreenScaffold("Studio", subtitle: "Text to speech") {
///         Card { … }
///     } actions: {
///         Button("Perform", systemImage: "play.fill") { … }.buttonStyle(.primary)
///     }
///
/// Pass `scrolls: false` for screens that manage their own scrolling or fill the height
/// (e.g. a full-height editor); the content then gets the remaining space.
struct ScreenScaffold<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    var scrolls: Bool = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @Environment(\.scaffoldScrolls) private var environmentScrolls
    @Environment(\.scaffoldScrollAnchor) private var scrollAnchor

    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.scrolls = scrolls
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        if scrolls && environmentScrolls {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    contentStack
                }
            }
            .scrollIndicators(.automatic)
            .scrollContentBackground(.hidden)
            .defaultScrollAnchor(scrollAnchor)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                contentStack
                    .frame(maxHeight: environmentScrolls ? .infinity : nil, alignment: .top)
            }
        }
    }

    /// One row: the title, the tagline on the same baseline, then the actions. The tagline yields: when it
    /// doesn't fit beside the actions it is hidden whole, never truncated.
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                Text(title)
                    .textRole(.marquee)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    ShownIfItFits() {
                        Text(subtitle)
                            .textRole(.body, color: .textSecondary)
                            .lineLimit(1)
                    }
                    .clipped()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.s) { actions }
                .fixedSize()
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, 22)
        .padding(.bottom, Theme.Space.l)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) { content }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.Space.screenInset)
            // A screen that fills the height keeps its own bottom edge (a pinned action bar sits close to it).
            .padding(.bottom, scrolls ? Theme.Space.xxl : Theme.Space.l)
    }
}

/// Shows its one subview at its ideal size when that fits the proposed width; otherwise takes no width at all
/// (clip it to hide the overflow). Keeps the subview's text baselines, so it can sit in a baseline-aligned row.
private struct ShownIfItFits: Layout {
    private func fits(_ ideal: CGSize, _ proposal: ProposedViewSize) -> Bool {
        guard let width = proposal.width else { return true }
        return ideal.width <= width + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let ideal = view.sizeThatFits(.unspecified)
        return fits(ideal, proposal) ? ideal : CGSize(width: 0, height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let ideal = view.sizeThatFits(.unspecified)
        view.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(ideal))
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard let view = subviews.first else { return nil }
        return bounds.minY + view.dimensions(in: .unspecified)[guide]
    }
}

extension ScreenScaffold where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, scrolls: scrolls, content: content) { EmptyView() }
    }
}

extension ScreenScaffold {
    /// Convenience: title and subtitle from an `AppSection`.
    init(_ section: AppSection, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(section.title, subtitle: section.subtitle, scrolls: scrolls,
                  content: content, actions: actions)
    }
}

extension ScreenScaffold where Actions == EmptyView {
    init(_ section: AppSection, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(section, scrolls: scrolls, content: content) { EmptyView() }
    }
}
