import Foundation

/// Plays takes the API was asked to play, one at a time, through the same player as the app (the mini-player shows it).
@MainActor
public enum APIPlayback {
    private static var player: AudioPlayer?

    /// Starts playing and returns; a newer take replaces one still playing.
    public static func play(_ url: URL, title: String) async {
        player?.stop()
        let p = AudioPlayer(title: title)
        p.subtitle = "From the local API"
        do {
            try await p.load(url: url, title: title)
            p.play()
            player = p
        } catch {
            player = nil
        }
    }
}
