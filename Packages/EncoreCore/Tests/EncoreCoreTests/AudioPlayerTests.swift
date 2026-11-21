import Foundation
import Testing
@testable import EncoreCore

/// The player's engine runs offline in these tests: nothing reaches an output device, so nothing is audible.
@MainActor @Suite(.serialized) struct AudioPlayerTests {
    private func makePlayer(seconds: Double = 2) -> AudioPlayer {
        let p = AudioPlayer(title: "Test", offline: true)
        p.load(buffer: AudioBuffer(samples: Signal.sine(440, dbfs: -20, seconds: seconds), sampleRate: 48_000))
        return p
    }

    @Test func stateChangesImmediately() async {
        let p = makePlayer()
        p.play()
        #expect(p.isPlaying)
        p.seek(to: 1.2)
        #expect(p.isPlaying && p.currentTime == 1.2)
        p.pause()
        #expect(!p.isPlaying)
        p.seek(to: 0.5)
        await p.drainEngine()
        #expect(p.currentTime == 0.5, "a pause's late position report must not overwrite a later seek")
        p.stop()
        #expect(!p.isPlaying && p.currentTime == 0)
        await p.drainEngine()
        #expect(p.lastError == nil)
    }

    @Test func hammeringCommandsLeavesConsistentState() async {
        let p = makePlayer()
        var rng = SystemRandomNumberGenerator()
        for i in 0..<600 {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0: p.play()
            case 1: p.pause()
            case 2: p.seek(to: Double.random(in: 0...2, using: &rng))
            case 3: p.stop()
            case 4: p.toggle()
            case 5: p.play(range: 0.3...0.9)
            default:
                if i.isMultiple(of: 50) {
                    p.load(buffer: AudioBuffer(samples: Signal.sine(220, dbfs: -20, seconds: 1.5), sampleRate: 24_000))
                } else {
                    p.volume = Float.random(in: 0...1, using: &rng)
                }
            }
            if i.isMultiple(of: 97) { await Task.yield() }
        }
        // Finish in a known state and let every queued engine command and callback land.
        p.seek(to: 1.2) // outside the audition range, so it ends that range
        p.play()
        await p.drainEngine()
        await Task.yield()
        #expect(p.isPlaying, "a stale completion or position report changed state")
        #expect(p.activeRange == nil && p.currentTime >= 1.2 && p.currentTime <= p.duration)
        p.pause()
        await p.drainEngine()
        await Task.yield()
        #expect(!p.isPlaying)
        p.stop()
        await p.drainEngine()
        #expect(!p.isPlaying && p.currentTime == 0 && p.lastError == nil)
    }

    @Test func finishingRewindsToTheRangeStart() async throws {
        let p = makePlayer(seconds: 1)
        p.play(range: 0.2...0.4)
        await p.drainEngine()
        await p.renderOffline(seconds: 0.5)
        for _ in 0..<100 where p.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!p.isPlaying, "\(String(describing: p.lastError)) t=\(p.currentTime)")
        #expect(p.currentTime == 0.2)
    }
}
