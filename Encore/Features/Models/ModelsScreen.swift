import SwiftUI

/// Models section. Placeholder: the Models feature replaces this body.
struct ModelsScreen: View {
    var body: some View {
        ScreenScaffold(.models) {
            EmptyState(symbol: "cpu", title: "No models installed",
                       message: "Download a model to start performing. Everything runs on this Mac.")
                .padding(.top, 60)
        }
    }
}
