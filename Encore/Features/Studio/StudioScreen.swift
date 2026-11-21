import SwiftUI

/// Studio section. Placeholder: the Studio feature replaces this body.
struct StudioScreen: View {
    var body: some View {
        ScreenScaffold(.studio) {
            EmptyState(symbol: "text.bubble", title: "The stage is set",
                       message: "Write a line, cast a voice, and press Perform. Your takes will gather here.")
                .padding(.top, 60)
        }
    }
}
