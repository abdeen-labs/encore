import SwiftUI

/// Changer section. Placeholder: the Changer feature replaces this body.
struct ChangerScreen: View {
    var body: some View {
        ScreenScaffold(.changer) {
            EmptyState(symbol: "arrow.triangle.swap", title: "Same performance, new voice",
                       message: "Drop a recording and choose who should say it instead.")
                .padding(.top, 60)
        }
    }
}
