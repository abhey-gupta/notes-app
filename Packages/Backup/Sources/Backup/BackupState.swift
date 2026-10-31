import Foundation
import InkModel
import os

/// What this library last copied to the backup folder (#174): `Application Support/Library/backup-state.json`,
/// beside `index.json`. A run diffs the library against it. Missing, damaged, newer, or about another folder:
/// empty, so the next run copies everything again (never less).
public struct BackupState: Hashable, Sendable {
    public static let formatVersion = 1
    static let fileName = "backup-state.json"

    /// One notebook as the backup folder has it.
    public struct Notebook: Hashable, Sendable {
        /// `Notebooks/` or `Trash/`.
        public var location: BackupLocation
        /// `manifest.json`'s modification date when it was copied: a run reads the manifest only if it moved.
        public var manifestModified: Date?
        /// Notebook `rev` of the copied manifest.
        public var rev: UInt64
        /// Pages with a copied stroke file, at the page `rev` copied.
        public var strokes: [PageID: UInt64]
        /// Copied immutable files (`images/…`, `backgrounds/…`), package-relative.
        public var assets: Set<String>
        /// Copied `thumbs/cover.heic`.
        public var cover: FileStamp?
        /// Bytes the backup holds for it.
        public var bytes: Int64

        /// Nothing copied yet.
        static func empty(at location: BackupLocation) -> Notebook {
            Notebook(location: location, manifestModified: nil, rev: 0, strokes: [:], assets: [], cover: nil, bytes: 0)
        }
    }

    /// The backup folder this state describes (its path).
    public var destination: String
    /// End of the last run that brought the folder up to date.
    public var lastBackup: Date?
    public var notebooks: [NotebookID: Notebook]

    public init(destination: String, lastBackup: Date? = nil, notebooks: [NotebookID: Notebook] = [:]) {
        self.destination = destination
        self.lastBackup = lastBackup
        self.notebooks = notebooks
    }

    /// Notebooks and bytes in the backup.
    public var totals: (notebooks: Int, bytes: Int64) {
        (notebooks.count, notebooks.values.reduce(0) { $0 + $1.bytes })
    }

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "backup")

    /// The state at `url` for `destination`; empty if missing, unreadable, or for another folder.
    public static func load(from url: URL, destination: String) -> BackupState {
        guard let data = try? Data(contentsOf: url) else { return BackupState(destination: destination) }
        guard let state = try? JSONDecoder().decode(BackupState.self, from: data) else {
            log.error("backup state unreadable: starting over")
            return BackupState(destination: destination)
        }
        return state.destination == destination ? state : BackupState(destination: destination)
    }

    /// Writes atomically.
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// A file's modification date and size.
public struct FileStamp: Hashable, Sendable, Codable {
    public var modified: Date
    public var size: Int64

    public init(modified: Date, size: Int64) {
        self.modified = modified
        self.size = size
    }
}

/// Dates are `Date`'s own encoding (a `Double`, which round-trips exactly), so a file's modification date
/// compares equal after a save and load. IDs are UUID strings.
extension BackupState: Codable {
    private enum CodingKeys: String, CodingKey { case formatVersion, destination, lastBackup, notebooks }

    private struct Row: Codable {
        var id: NotebookID
        var location: BackupLocation
        var manifestModified: Date?
        var rev: UInt64
        var strokes: [String: UInt64]
        var assets: [String]
        var cover: FileStamp?
        var bytes: Int64
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c, debugDescription: "formatVersion \(version)")
        }
        destination = try c.decode(String.self, forKey: .destination)
        lastBackup = try c.decodeIfPresent(Date.self, forKey: .lastBackup)
        notebooks = [:]
        for row in try c.decode([Row].self, forKey: .notebooks) {
            let strokes = row.strokes.compactMap { key, rev in PageID(uuidString: key).map { ($0, rev) } }
            notebooks[row.id] = Notebook(
                location: row.location, manifestModified: row.manifestModified, rev: row.rev,
                strokes: Dictionary(strokes, uniquingKeysWith: { first, _ in first }), assets: Set(row.assets), cover: row.cover,
                bytes: row.bytes
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(destination, forKey: .destination)
        try c.encodeIfPresent(lastBackup, forKey: .lastBackup)
        let rows = notebooks.sorted { $0.key < $1.key }.map { id, n in
            Row(
                id: id, location: n.location, manifestModified: n.manifestModified, rev: n.rev,
                strokes: Dictionary(uniqueKeysWithValues: n.strokes.map { ($0.key.description, $0.value) }), assets: n.assets.sorted(),
                cover: n.cover, bytes: n.bytes
            )
        }
        try c.encode(rows, forKey: .notebooks)
    }
}
