import Foundation

// Threading contract for every store in this folder
// --------------------------------------------------
// Each store is a `@MainActor @Observable` class: SwiftUI reads its collections directly and they update
// as soon as a mutation returns. Mutations are main-actor methods; the service layer calls them with
// `await` from any isolation. Lookups the service layer needs while generating (`VoiceLibrary.engineVoice`,
// `PronunciationStore.enabledEntries`, `PresetStore.preset`, `AppSettings.snapshot`) are `nonisolated` and
// read a lock-protected snapshot, so they never wait for the main actor. Slow file work (copying audio,
// zipping) runs off the main actor inside the async methods.
//
// History is the exception in shape: its database (`HistoryDatabase`) is a `Sendable` class whose async
// methods run on GRDB's own queues from any isolation; `HistoryStore` is the `@MainActor @Observable`
// view of it, kept current by database observation.

enum StoreFiles {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    /// Writes JSON atomically (temp file + rename), creating the directory if needed.
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    /// Reads JSON; a missing file gives nil, a corrupt one throws.
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    /// Keeps a damaged file aside instead of overwriting it, so nothing the user made is silently lost.
    static func quarantine(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = url.deletingPathExtension().appendingPathExtension("damaged-\(stamp).\(url.pathExtension)")
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    /// Runs a short-lived tool and returns its standard output (small outputs only).
    static func output(_ executable: String, _ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StoreError.toolFailed("\((executable as NSString).lastPathComponent) exited with \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a command-line tool to completion off the calling thread.
    static func run(_ executable: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { c.resume() }
                else {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmed()
                    c.resume(throwing: StoreError.toolFailed("\((executable as NSString).lastPathComponent): \(message)"))
                }
            }
            do { try process.run() } catch { c.resume(throwing: error) }
        }
    }
}

public enum StoreError: LocalizedError, Equatable {
    case notFound(String)
    case invalidFile(String)
    case toolFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) couldn't be found."
        case .invalidFile(let why): why
        case .toolFailed(let why): why
        }
    }
}

extension String {
    /// Case- and diacritic-insensitive containment, for search fields.
    func looselyContains(_ needle: String) -> Bool {
        needle.isEmpty || range(of: needle, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
    }
}
