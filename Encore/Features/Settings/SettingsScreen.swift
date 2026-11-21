import SwiftUI

/// Settings section. Placeholder: the Settings feature replaces this body.
struct SettingsScreen: View {
    var body: some View {
        ScreenScaffold(.settings) {
            EmptyState(symbol: "slider.horizontal.3", title: "Nothing to adjust yet",
                       message: "Preferences will appear here as features arrive.")
                .padding(.top, 60)
        }
    }
}
