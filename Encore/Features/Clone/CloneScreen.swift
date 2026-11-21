import SwiftUI

/// Clone section. Placeholder: the Clone feature replaces this body.
struct CloneScreen: View {
    var body: some View {
        ScreenScaffold(.clone) {
            EmptyState(symbol: "mic", title: "Bring a voice to the stage",
                       message: "Record or drop ten seconds of clean speech and Encore will learn to perform it.")
                .padding(.top, 60)
        }
    }
}
