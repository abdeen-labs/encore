import Foundation

public enum TimestampGranularity: String, Codable, Sendable, CaseIterable {
    case none, segment, word
}

public struct Transcript: Codable, Sendable, Equatable {
    public var text: String
    public var language: String?
    public var duration: TimeInterval?
    public var segments: [Segment]

    public init(text: String, language: String? = nil, duration: TimeInterval? = nil, segments: [Segment] = []) {
        self.text = text; self.language = language; self.duration = duration; self.segments = segments
    }

    public struct Segment: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        public var words: [Word]?
        public init(id: Int, start: TimeInterval, end: TimeInterval, text: String, words: [Word]? = nil) {
            self.id = id; self.start = start; self.end = end; self.text = text; self.words = words
        }
    }

    public struct Word: Codable, Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var text: String
        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start; self.end = end; self.text = text
        }
    }
}
