import Foundation

/// Where deleted files go. The app uses the user's Trash, so a slip can be undone from Finder; tests and headless
/// runs pass a folder of their own so they never touch the real Trash.
public struct FileTrash: Sendable {
    private let move: @Sendable (URL) throws -> Void

    public init(move: @escaping @Sendable (URL) throws -> Void) { self.move = move }

    /// The user's Trash (`FileManager.trashItem`).
    public static let system = FileTrash { url in try FileManager.default.trashItem(at: url, resultingItemURL: nil) }

    /// A plain folder standing in for the Trash. Created on first use; a name already there gets a numbered suffix,
    /// the way the Trash itself keeps both.
    public static func folder(_ folder: URL) -> FileTrash {
        FileTrash { url in
            let fm = FileManager.default
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
            var dest = folder.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            try fm.moveItem(at: url, to: dest)
        }
    }

    /// Moves `url` to the Trash. When that fails (a volume without a Trash, say) the item is removed instead, as
    /// voice deletion does; only a failure to remove it throws.
    public func discard(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if (try? move(url)) != nil { return }
        try FileManager.default.removeItem(at: url)
    }
}
