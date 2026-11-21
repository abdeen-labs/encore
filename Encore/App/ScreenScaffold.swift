import SwiftUI

extension EnvironmentValues {
    /// When false, `ScreenScaffold` lays its content out at full height without a scroll view.
    /// The snapshot renderer uses this for `-full` captures.
    @Entry var scaffoldScrolls: Bool = true
}

/// The standard screen frame: a playbill header (optional eyebrow, display-serif title,
/// subtitle, trailing actions) above scrolling content.
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
    var eyebrow: String?
    var scrolls: Bool = true
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    @Environment(\.scaffoldScrolls) private var environmentScrolls

    init(_ title: String, subtitle: String? = nil, eyebrow: String? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
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
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                contentStack
                    .frame(maxHeight: environmentScrolls ? .infinity : nil, alignment: .top)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(eyebrow).textRole(.eyebrow, color: Color.tungsten.opacity(0.75))
                }
                Text(title)
                    .textRole(.marquee)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.ui(13.5)).foregroundStyle(.textSecondary)
                }
            }
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: Theme.Space.s) { actions }
                .padding(.bottom, 4)
        }
        .padding(.horizontal, Theme.Space.screenInset)
        .padding(.top, 34)
        .padding(.bottom, Theme.Space.xl)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) { content }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Theme.Space.screenInset)
            .padding(.bottom, Theme.Space.xxl)
    }
}

extension ScreenScaffold where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil, eyebrow: String? = nil, scrolls: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, eyebrow: eyebrow, scrolls: scrolls, content: content) { EmptyView() }
    }
}

extension ScreenScaffold {
    /// Convenience: title, subtitle and eyebrow from an `AppSection`.
    init(_ section: AppSection, scrolls: Bool = true,
         @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(section.title, subtitle: section.subtitle, eyebrow: section.eyebrow, scrolls: scrolls,
                  content: content, actions: actions)
    }
}

extension ScreenScaffold where Actions == EmptyView {
    init(_ section: AppSection, scrolls: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(section, scrolls: scrolls, content: content) { EmptyView() }
    }
}
