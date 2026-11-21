import SwiftUI

/// Long-lived app state shared by every screen. The real app and the snapshot renderer both
/// build one of these and inject it with `.appDependencies(_:)`, so anything added here is
/// available in snapshots too. Add your feature's models here.
@Observable final class AppDependencies {
    let router: Router
    let toasts: ToastCenter

    init(router: Router = Router(), toasts: ToastCenter = ToastCenter()) {
        self.router = router
        self.toasts = toasts
    }
}

extension View {
    /// Injects every shared dependency into the environment.
    func appDependencies(_ deps: AppDependencies) -> some View {
        self
            .environment(deps)
            .environment(deps.router)
            .environment(deps.toasts)
    }
}
