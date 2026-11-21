import Foundation

/// The one call the service layer needs for a TTS script: parse markup, split into chunks that fit the
/// model, apply pronunciations, and say how much silence goes where.
///
/// Chunking runs on the original script so every chunk's range points back into it (progress display,
/// per-chunk regeneration); pronunciations are applied to each chunk's text afterwards.
public struct ScriptPlan: Sendable {
    public enum Item: Sendable, Hashable {
        case speech(SpeechChunk)
        /// An explicit pause tag (adjacent tags merged), seconds.
        case pause(TimeInterval, range: Range<String.Index>)
    }

    public struct SpeechChunk: Sendable, Hashable {
        /// What to send to the model: pronunciations applied, whitespace collapsed, native tags intact.
        public var text: String
        /// The chunk exactly as written in the script.
        public var sourceText: String
        /// `nil` = the request's own voice.
        public var voice: VoiceSelection?
        public var range: Range<String.Index>
        public var utf16Range: NSRange
        public var boundary: ChunkBoundary
        /// Silence to put after this chunk, seconds. Zero before an explicit pause and at the very end.
        public var gapAfter: TimeInterval
    }

    public var items: [Item]
    public var parsed: ParsedScript

    public var chunks: [SpeechChunk] { items.compactMap { if case .speech(let c) = $0 { c } else { nil } } }
    public var issues: [ScriptIssue] { parsed.issues }
}

public struct ScriptPlanner: Sendable {
    public var parser: ScriptParser
    /// `nil` or ≤ 0 = don't chunk (paragraphs still become separate chunks).
    public var maxChunkCharacters: Int?
    public var pronunciations: PronunciationApplier
    /// Gap between chunks of running text.
    public var chunkGap: TimeInterval
    /// Gap after a paragraph (blank line).
    public var paragraphGap: TimeInterval

    public init(parser: ScriptParser = ScriptParser(), maxChunkCharacters: Int?, pronunciations: [PronunciationEntry] = [],
                chunkGap: TimeInterval = 0.15, paragraphGap: TimeInterval? = nil) {
        self.parser = parser
        self.maxChunkCharacters = maxChunkCharacters
        self.pronunciations = PronunciationApplier(entries: pronunciations)
        self.chunkGap = chunkGap
        self.paragraphGap = paragraphGap ?? max(chunkGap * 2.5, 0.4)
    }

    /// Planner configured from a request and the model it runs on.
    public init(request: SpeechRequest, manifest: ModelManifest, library: [Voice], pronunciations: [PronunciationEntry]) {
        self.init(parser: ScriptParser(vocabulary: TagVocabulary(manifest: manifest),
                                       voices: ScriptVoiceDirectory(library: library, presets: manifest.presetVoices)),
                  maxChunkCharacters: request.autoChunk ? manifest.maxChunkCharacters : nil,
                  pronunciations: request.applyPronunciations ? pronunciations : [],
                  chunkGap: request.chunkGapSeconds)
    }

    public func plan(_ script: String) -> ScriptPlan {
        let parsed = parser.parse(script)
        let chunker = TextChunker(maxCharacters: maxChunkCharacters ?? 0)
        var items: [ScriptPlan.Item] = []
        for segment in parsed.segments {
            switch segment.content {
            case .pause(let s):
                items.append(.pause(s, range: segment.range))
            case .speech:
                for c in chunker.chunks(of: script, in: segment.range) {
                    let text = pronunciations.apply(to: c.text).collapsingWhitespace()
                    guard !text.isEmpty else { continue }
                    items.append(.speech(.init(text: text, sourceText: c.text, voice: segment.voice, range: c.range,
                                               utf16Range: c.utf16Range, boundary: c.boundary, gapAfter: 0)))
                }
            }
        }
        // Gaps: between consecutive speech chunks only.
        for i in items.indices {
            guard case .speech(var c) = items[i] else { continue }
            if i + 1 < items.count, case .speech = items[i + 1] {
                c.gapAfter = c.boundary == .paragraph ? paragraphGap : chunkGap
                // A paragraph break between two segments (e.g. around a voice tag) also reads as a paragraph.
                if c.boundary == .end, case .speech(let next) = items[i + 1],
                   Self.hasBlankLine(script[c.range.upperBound..<next.range.lowerBound]) {
                    c.gapAfter = paragraphGap
                }
            }
            items[i] = .speech(c)
        }
        return ScriptPlan(items: items, parsed: parsed)
    }

    private static func hasBlankLine(_ s: Substring) -> Bool {
        var newlines = 0
        for c in s where c.isNewline || c == "\u{2029}" { newlines += c == "\u{2029}" ? 2 : 1 }
        return newlines >= 2
    }
}
