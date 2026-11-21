import SwiftUI

/// Design section. Placeholder: the Design feature replaces this body.
struct DesignScreen: View {
    var body: some View {
        ScreenScaffold(.design) {
            EmptyState(symbol: "wand.and.stars", title: "Describe a voice",
                       message: "\"A weathered sea captain, low and unhurried.\" Write a description and audition what comes back.")
                .padding(.top, 60)
        }
    }
}
