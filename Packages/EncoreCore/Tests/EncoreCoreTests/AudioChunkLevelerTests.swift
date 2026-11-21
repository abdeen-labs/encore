import Foundation
import Testing
@testable import EncoreCore

private func tone(_ amplitude: Float, seconds: Double, rate: Double = 24000, hz: Double = 220) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / rate)) }
}

@Suite struct AudioChunkLevelerTests {
    let rate = 24000.0

    /// The reported case: one chunk holds a loud burst, so its speech was scaled far below the next chunk's.
    @Test func quietChunkWithALoudBurstIsBroughtUpToItsNeighbor() throws {
        var first = tone(0.05, seconds: 6)                       // speech, pushed down by the burst…
        let burst = tone(0.5, seconds: 0.3, hz: 600)             // …a laugh at the model's peak level
        first.replaceSubrange(Int(3 * rate)..<Int(3 * rate) + burst.count, with: burst)
        let second = tone(0.16, seconds: 4)                      // the next chunk, about 10 dB louder

        let before = try #require(ChunkLeveler.speechLevel(first, sampleRate: rate)).level
        let neighbor = try #require(ChunkLeveler.speechLevel(second, sampleRate: rate)).level
        #expect(neighbor - before > 9)

        let out = ChunkLeveler.level([first, second], sampleRate: rate)
        let a = try #require(ChunkLeveler.speechLevel(out[0], sampleRate: rate)).level
        let b = try #require(ChunkLeveler.speechLevel(out[1], sampleRate: rate)).level
        #expect(abs(a - b) < 1)
        #expect(out.flatMap { $0 }.map(abs).max()! <= 0.981)     // the burst is not allowed to clip
        // The burst keeps its size relative to the speech around it.
        let burstPeak = out[0][Int(3 * rate)..<Int(3 * rate) + burst.count].map(abs).max()!
        let speechPeak = out[0][0..<Int(2 * rate)].map(abs).max()!
        #expect(abs(burstPeak / speechPeak - 10) < 0.5)
    }

    @Test func matchedChunksAreLeftUntouched() {
        let a = tone(0.2, seconds: 3), b = tone(0.21, seconds: 5)
        #expect(ChunkLeveler.gains(for: [a, b], sampleRate: rate) == [0, 0])
        #expect(ChunkLeveler.level([a, b], sampleRate: rate) == [a, b])
    }

    @Test func correctionIsCappedAndSilenceIsIgnored() {
        let whisper = tone(0.001, seconds: 3), loud = tone(0.5, seconds: 3)
        let silence = [Float](repeating: 0, count: Int(2 * rate))
        let gains = ChunkLeveler.gains(for: [whisper, silence, loud], sampleRate: rate)
        #expect(gains[1] == 0)
        #expect(gains.allSatisfy { abs($0) <= ChunkLeveler.maxGainDB })
        #expect(ChunkLeveler.speechLevel(silence, sampleRate: rate) == nil)
        // One piece alone has nothing to be matched to.
        #expect(ChunkLeveler.gains(for: [loud], sampleRate: rate) == [0])
    }

    @Test func pausesInsideAChunkDoNotLowerItsLevel() throws {
        var withPause = tone(0.2, seconds: 2)
        withPause += [Float](repeating: 0, count: Int(1.5 * rate))
        withPause += tone(0.2, seconds: 2)
        let steady = try #require(ChunkLeveler.speechLevel(tone(0.2, seconds: 4), sampleRate: rate)).level
        let paused = try #require(ChunkLeveler.speechLevel(withPause, sampleRate: rate)).level
        #expect(abs(steady - paused) < 0.5)
    }
}
