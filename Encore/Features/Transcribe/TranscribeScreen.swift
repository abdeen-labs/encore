import SwiftUI

/// Transcribe section. Placeholder: the Transcribe feature replaces this body.
struct TranscribeScreen: View {
    var body: some View {
        ScreenScaffold(.transcribe) {
            EmptyState(symbol: "captions.bubble", title: "Nothing to transcribe",
                       message: "Drop audio or record from the microphone to get text with timings.")
                .padding(.top, 60)
        }
    }
}
