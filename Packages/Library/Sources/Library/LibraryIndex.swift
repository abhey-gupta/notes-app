import CoreGraphics
import Document
import Foundation
import InkModel

/// Contents of `Application Support/Library/index.json` (ARCHITECTURE.md §8).
///
/// `{"formatVersion": 1, "notebooks": {"id": [...], "title": [...], ...}, "folders": [...], "trash": [...]}`.
/// Notebooks are stored column-wise (one array per field, all the same length; see ``NotebookColumns``):
/// decoding then walks a few flat arrays instead of a keyed object per notebook, ~35 % faster on the
/// launch path. Unknown keys and columns are ignored (a newer build's additions don't make an older one
/// rebuild); a newer `formatVersion` is rejected.
public struct LibraryIndex: Hashable, Sendable {
    /// Version written by, and the newest readable by, this build.
    public static let formatVersion = 1

    /// Notebooks, most recently modified first.
    public var notebooks: [LibraryEntry]
    /// Folders in display order.
    public var folders: [LibraryFolder]
    /// Deleted notebooks awaiting purge.
    public var trash: [TrashedNotebook]

    /// Creates an index. Notebooks are sorted most recently modified first.
    public init(notebooks: [LibraryEntry] = [], folders: [LibraryFolder] = [], trash: [TrashedNotebook] = []) {
        self.notebooks = notebooks
        self.folders = folders
        self.trash = trash
        sortNotebooks()
    }

    /// Restores the canonical order: modified descending, then ID descending (newest first) for ties.
    mutating func sortNotebooks() {
        notebooks.sort { $0.modifiedAt != $1.modifiedAt ? $0.modifiedAt > $1.modifiedAt : $0.id > $1.id }
    }

    /// Compact JSON (no pretty printing: the index is machine-read on the launch path).
    public func encoded() throws(LibraryError) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        do {
            return try encoder.encode(self)
        } catch {
            throw .corruptIndex(reason: "encode: \(error)")
        }
    }

    /// Decodes index bytes.
    /// - Throws: ``LibraryError/unsupportedFormatVersion(found:supported:)`` or ``LibraryError/corruptIndex(reason:)``.
    public static func decode(_ data: Data) throws(LibraryError) -> LibraryIndex {
        do {
            return try JSONDecoder().decode(LibraryIndex.self, from: data)
        } catch let error as LibraryError {
            throw error
        } catch {
            throw .corruptIndex(reason: "\(error)")
        }
    }
}

extension LibraryIndex: Codable {
    private enum CodingKeys: String, CodingKey { case formatVersion, notebooks, folders, trash }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version >= 1 else { throw LibraryError.corruptIndex(reason: "formatVersion \(version)") }
        guard version <= Self.formatVersion else {
            throw LibraryError.unsupportedFormatVersion(found: version, supported: Self.formatVersion)
        }
        // Written sorted; decoding trusts that rather than re-sorting on the launch path.
        notebooks = try c.decode(NotebookColumns.self, forKey: .notebooks).entries
        folders = try c.decodeIfPresent([LibraryFolder].self, forKey: .folders) ?? []
        trash = try c.decodeIfPresent([TrashedNotebook].self, forKey: .trash) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(NotebookColumns(notebooks), forKey: .notebooks)
        try c.encode(folders, forKey: .folders)
        try c.encode(trash, forKey: .trash)
    }
}

/// ``LibraryIndex/notebooks`` as columns. Enum and ID columns are decoded as strings and converted in one
/// pass (cheaper than a `Decodable` round trip per value). Optional columns may be absent.
struct NotebookColumns: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, folderID, cover, paper, theme, createdAt, modifiedAt, pageCount, pageWidth, pageHeight
        case packagePath, coverThumbnailPath, rev
    }

    let entries: [LibraryEntry]

    init(_ entries: [LibraryEntry]) {
        self.entries = entries
    }

    /// Column access with length checks against the `id` column.
    private struct Reader {
        let c: KeyedDecodingContainer<CodingKeys>
        let count: Int

        func column<T: Decodable>(_ key: CodingKeys, _: T.Type = T.self) throws -> [T] {
            try checked(c.decode([T].self, forKey: key), key)
        }

        func optionalColumn<T: Decodable>(_ key: CodingKeys, _: T.Type = T.self) throws -> [T?] {
            guard let values = try c.decodeIfPresent([T?].self, forKey: key) else { return Array(repeating: nil, count: count) }
            return try checked(values, key)
        }

        private func checked<T>(_ values: [T], _ key: CodingKeys) throws -> [T] {
            guard values.count == count else {
                throw LibraryError.corruptIndex(reason: "column \(key.stringValue): \(values.count) ≠ \(count)")
            }
            return values
        }
    }

    private static func parse<T>(_ raw: String, _ key: CodingKeys, _ make: (String) -> T?) throws -> T {
        guard let value = make(raw) else { throw LibraryError.corruptIndex(reason: "\(key.stringValue): \(raw)") }
        return value
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ids = try c.decode([String].self, forKey: .id)
        let count = ids.count
        let r = Reader(c: c, count: count)

        let titles: [String] = try r.column(.title)
        let folders: [String?] = try r.optionalColumn(.folderID)
        let covers: [String] = try r.column(.cover)
        let papers: [String] = try r.column(.paper)
        let themes: [String] = try r.column(.theme)
        let created: [Int64] = try r.column(.createdAt)
        let modified: [Int64] = try r.column(.modifiedAt)
        let pageCounts: [Int] = try r.column(.pageCount)
        let widths: [Double] = try r.column(.pageWidth)
        let heights: [Double] = try r.column(.pageHeight)
        let paths: [String] = try r.column(.packagePath)
        let thumbs: [String?] = try r.optionalColumn(.coverThumbnailPath)
        let revs: [UInt64?] = try r.optionalColumn(.rev)

        var entries: [LibraryEntry] = []
        entries.reserveCapacity(count)
        for i in 0 ..< count {
            try entries.append(LibraryEntry(
                id: Self.parse(ids[i], .id, NotebookID.init(uuidString:)),
                title: titles[i],
                folderID: folders[i].map { try Self.parse($0, .folderID, FolderID.init(uuidString:)) },
                cover: Self.parse(covers[i], .cover, CoverColor.init(rawValue:)),
                paper: Self.parse(papers[i], .paper, PaperStyle.init(rawValue:)),
                theme: Self.parse(themes[i], .theme, PaperTheme.init(rawValue:)),
                createdAt: Date(libraryMilliseconds: created[i]),
                modifiedAt: Date(libraryMilliseconds: modified[i]),
                pageCount: pageCounts[i],
                pageSize: CGSize(width: widths[i], height: heights[i]),
                packagePath: paths[i],
                coverThumbnailPath: thumbs[i],
                rev: revs[i] ?? 0
            ))
        }
        self.entries = entries
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entries.map(\.id), forKey: .id)
        try c.encode(entries.map(\.title), forKey: .title)
        try c.encode(entries.map(\.folderID), forKey: .folderID)
        try c.encode(entries.map(\.cover), forKey: .cover)
        try c.encode(entries.map(\.paper), forKey: .paper)
        try c.encode(entries.map(\.theme), forKey: .theme)
        try c.encode(entries.map(\.createdAt.libraryMilliseconds), forKey: .createdAt)
        try c.encode(entries.map(\.modifiedAt.libraryMilliseconds), forKey: .modifiedAt)
        try c.encode(entries.map(\.pageCount), forKey: .pageCount)
        try c.encode(entries.map { Double($0.pageSize.width) }, forKey: .pageWidth)
        try c.encode(entries.map { Double($0.pageSize.height) }, forKey: .pageHeight)
        try c.encode(entries.map(\.packagePath), forKey: .packagePath)
        try c.encode(entries.map(\.coverThumbnailPath), forKey: .coverThumbnailPath)
        try c.encode(entries.map(\.rev), forKey: .rev)
    }
}

/// Where the library lives. Paths in the index are relative to these roots.
public struct LibraryLocations: Hashable, Sendable {
    /// `Documents/Notebooks`: the `.nb` packages.
    public var notebooksDirectory: URL
    /// `Application Support/Library`: index and trash.
    public var libraryDirectory: URL

    /// Custom roots (tests).
    public init(notebooksDirectory: URL, libraryDirectory: URL) {
        self.notebooksDirectory = notebooksDirectory
        self.libraryDirectory = libraryDirectory
    }

    /// The app container layout under `root`: `root/Documents/Notebooks`, `root/Application Support/Library`.
    public init(root: URL) {
        self.init(
            notebooksDirectory: NotebookPackage.notebooksDirectory(in: root.appending(path: "Documents", directoryHint: .isDirectory)),
            libraryDirectory: root.appending(path: "Application Support/Library", directoryHint: .isDirectory)
        )
    }

    /// The app's container: `Documents/Notebooks` and `Application Support/Library`.
    public static var standard: LibraryLocations {
        LibraryLocations(
            notebooksDirectory: NotebookPackage.notebooksDirectory(),
            libraryDirectory: URL.applicationSupportDirectory.appending(path: "Library", directoryHint: .isDirectory)
        )
    }

    /// `index.json`.
    public var indexURL: URL {
        libraryDirectory.appending(path: "index.json", directoryHint: .notDirectory)
    }

    /// Where an unreadable index is moved before a rebuild, for diagnosis.
    public var corruptIndexURL: URL {
        libraryDirectory.appending(path: "index.corrupt.json", directoryHint: .notDirectory)
    }

    /// `Trash/`: deleted packages, by ID.
    public var trashDirectory: URL {
        libraryDirectory.appending(path: "Trash", directoryHint: .isDirectory)
    }

    /// Absolute URL of a path relative to the Notebooks root.
    public func notebooksURL(_ relativePath: String) -> URL {
        notebooksDirectory.appending(path: relativePath)
    }

    /// Package URL for an entry.
    public func packageURL(for entry: LibraryEntry) -> URL {
        notebooksDirectory.appending(path: entry.packagePath, directoryHint: .isDirectory)
    }

    /// `cover.heic` URL for an entry, if the index saw one.
    public func coverThumbnailURL(for entry: LibraryEntry) -> URL? {
        entry.coverThumbnailPath.map { notebooksDirectory.appending(path: $0, directoryHint: .notDirectory) }
    }
}

/// Why a library operation failed. Failed operations leave the index (memory and disk) unchanged.
public enum LibraryError: Error, Hashable, Sendable {
    /// `index.json` was written by a newer Notespace.
    case unsupportedFormatVersion(found: Int, supported: Int)
    /// `index.json` is not valid.
    case corruptIndex(reason: String)
    /// No notebook with this ID in the library (or in the trash, for restore).
    case notFound(NotebookID)
    /// No folder with this ID.
    case unknownFolder(FolderID)
    /// Package read/write failed.
    case document(DocumentError)
    /// File system failure at `url`.
    case io(URL, reason: String)
}

extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormatVersion(found, supported):
            "The library index is from a newer Notespace (format \(found); this version reads up to \(supported))."
        case let .corruptIndex(reason):
            "The library index is damaged (\(reason))."
        case let .notFound(id):
            "No notebook \(id) in the library."
        case let .unknownFolder(id):
            "No folder \(id)."
        case let .document(error):
            error.localizedDescription
        case let .io(url, reason):
            "Could not access \(url.lastPathComponent): \(reason)"
        }
    }
}
