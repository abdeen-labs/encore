import SwiftUI

/// Voices section. Placeholder: the Voices feature replaces this body.
struct VoicesScreen: View {
    @Environment(Router.self) private var router

    var body: some View {
        ScreenScaffold(.voices) {
            EmptyState(symbol: "person.wave.2", title: "No one in the company yet",
                       message: "Cloned and designed voices appear here, ready to be cast.") {
                Button("Clone a voice") { router.go(.clone) }
                    .buttonStyle(.secondary)
            }
                .padding(.top, 60)
        }
    }
}
