import Foundation

/// Which runtime runs each engine best. With the runtime left on Automatic, the service tries this one first.
/// A runtime picked in Settings still wins, and when the best one can't do a request or isn't ready, the other
/// one runs it.
///
/// Picked by comparing the MLX Swift and Python (mlx-audio) ports against each other and upstream, 2026-11-22.
/// Engines not listed here run about the same in both, so native goes first: it needs no helper process.
/// Engines only one runtime has (Chatterbox Multilingual, the voice changer) need no entry.
public enum BestRuntime {
    public struct Pick: Sendable, Equatable {
        public var runtime: EngineRuntime
        /// Why, in a phrase that follows "runs here because it…".
        public var reason: String
    }

    public static let picks: [String: Pick] = [
        "voxcpm2": Pick(runtime: .python,
                        reason: "keeps a cloned voice's accent by reading the clip's transcript too"),
        "whisper": Pick(runtime: .python,
                        reason: "detects the language, retries passages it gets stuck on, and times words"),
        "qwen3_tts": Pick(runtime: .mlxSwift,
                          reason: "keeps your repetition penalty when cloning (the Python version raises it to 1.5)"),
        "omnivoice": Pick(runtime: .mlxSwift,
                          reason: "evens out loudness and fades the ends (the Python version returns the raw output)"),
        "soprano": Pick(runtime: .mlxSwift,
                        reason: "applies the repetition penalty (the Python version ignores it)"),
    ]

    public static func pick(for engine: String) -> Pick? { picks[engine] }
}
