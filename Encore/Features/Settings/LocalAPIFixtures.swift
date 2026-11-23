#if DEBUG
import EncoreCore
import SwiftUI

/// Settings → Local API states for `--snapshot`. Nothing listens: the status is set, not earned.
///
///     Encore --snapshot <dir> --snapshot-only Settings-LocalAPI,Settings-LocalAPI-Failed
@MainActor
enum LocalAPIFixtures {
    static var all: [FeatureFixture] {
        [state("Settings-LocalAPI", .running(port: 7171)),
         state("Settings-LocalAPI-Failed", .failed(LocalHTTPServer.StartError.portInUse(7171).localizedDescription))]
    }

    private static func state(_ name: String, _ status: LocalAPIController.Status) -> FeatureFixture {
        FeatureFixture(name: name, section: .settings, size: CGSize(width: 1180, height: 2600), prepare: { deps in
            deps.settings.localAPIEnabled = true
            deps.localAPI.showFixture(status)
            return .init(settingsModel: FeatureFixture.settingsModel(ffmpeg: true, python: FeatureFixture.pythonFound))
        })
    }
}
#endif
