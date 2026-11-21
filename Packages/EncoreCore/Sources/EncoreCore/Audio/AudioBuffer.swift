import Foundation

/// Mono 32-bit float PCM. The one audio currency inside Encore.
public struct AudioBuffer: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double

    public init(samples: [Float] = [], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var isEmpty: Bool { samples.isEmpty }

    public static func silence(_ seconds: TimeInterval, sampleRate: Double) -> AudioBuffer {
        AudioBuffer(samples: [Float](repeating: 0, count: max(0, Int(seconds * sampleRate))), sampleRate: sampleRate)
    }
}
