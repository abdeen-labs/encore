import EncoreCore
import SwiftUI

/// Says when a model isn't running where it runs best (`ModelShelf.missedBestRuntime`), what that costs, and
/// where to fix it. Shown under the screen's other notices.
struct BestRuntimeNote: View {
    let manifest: ModelManifest
    let pick: BestRuntime.Pick
    var onOpenSettings: () -> Void

    var body: some View {
        Banner(.neutral, title: "\(manifest.name) runs best \(Self.place(pick.runtime))",
               message: "There, it \(pick.reason). \(Self.unavailable(pick.runtime)), so \(manifest.name) runs \(Self.place(pick.runtime == .python ? .mlxSwift : .python)) for now.") {
            Button("Open Settings", action: onOpenSettings).buttonStyle(.secondary).controlSize(.small)
        }
    }

    static func place(_ runtime: EngineRuntime) -> String {
        runtime == .python ? "in the Python helper" : "natively"
    }

    private static func unavailable(_ runtime: EngineRuntime) -> String {
        runtime == .python ? "The Python helper isn't set up on this Mac" : "The native runtime can't run it here"
    }
}
