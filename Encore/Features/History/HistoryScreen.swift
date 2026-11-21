import SwiftUI

/// History section. Placeholder: the History feature replaces this body.
struct HistoryScreen: View {
    @Environment(Router.self) private var router

    var body: some View {
        ScreenScaffold(.history) {
            EmptyState(symbol: "clock.arrow.circlepath", title: "No takes yet",
                       message: "Everything you generate is kept here, newest first.") {
                Button("Go to Studio") { router.go(.studio) }
                    .buttonStyle(.secondary)
            }
                .padding(.top, 60)
        }
    }
}
