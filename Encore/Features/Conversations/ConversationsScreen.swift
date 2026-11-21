import SwiftUI

/// Conversations section. Placeholder: the Conversations feature replaces this body.
struct ConversationsScreen: View {
    var body: some View {
        ScreenScaffold(.conversations) {
            EmptyState(symbol: "bubble.left.and.bubble.right", title: "Write a scene",
                       message: "Give each speaker a voice, write the dialogue, and stage the whole conversation in one take.")
                .padding(.top, 60)
        }
    }
}
