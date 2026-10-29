import CoreGraphics
import Document
import Foundation
import InkModel

/// Tag for ``FolderID``.
public enum FolderTag {}
/// Identifies a ``LibraryFolder`` (UUIDv7).
public typealias FolderID = TypedID<FolderTag>

/// One notebook in the library index (ARCHITECTURE.md §8): everything the library grid and the editor's
/// first frame need, so launch never opens a package.
///
/// The package manifest is the source of truth for notebook fields; the index is a cache of them plus
/// library-only state (``folderID``). Paths are relative to the Notebooks root, never absolute (the app
/// container moves between installs).
public struct LibraryEntry: Hashable, Sendable, Identifiable {
    /// Notebook identity; also names the package.
    public let id: NotebookID
    /// Display title.
    public var title: String
    /// Folder, if any.
    public var folderID: FolderID?
    /// Cover swatch.
    public var cover: CoverColor
    /// Paper pattern.
    public var paper: PaperStyle
    /// Paper color.
    public var theme: PaperTheme
    /// Creation time.
    public var createdAt: Date
    /// Last modification (manifest `modifiedAt`).
    public var modifiedAt: Date
    /// Number of pages.
    public var pageCount: Int
    /// Page size in points (all pages).
    public var pageSize: CGSize
    /// Package directory relative to the Notebooks root, e.g. `<id>.nb`.
    public var packagePath: String
    /// `thumbs/cover.heic` relative to the Notebooks root, when it existed at the last index update.
    public var coverThumbnailPath: String?
    /// Manifest `rev` this entry reflects; stale checkpoints (lower rev) are ignored.
    public var rev: UInt64

    /// Creates an entry.
    public init(
        id: NotebookID,
        title: String,
        folderID: FolderID? = nil,
        cover: CoverColor,
        paper: PaperStyle,
        theme: PaperTheme,
        createdAt: Date,
        modifiedAt: Date,
        pageCount: Int,
        pageSize: CGSize,
        packagePath: String,
        coverThumbnailPath: String? = nil,
        rev: UInt64 = 0
    ) {
        self.id = id
        self.title = title
        self.folderID = folderID
        self.cover = cover
        self.paper = paper
        self.theme = theme
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.pageCount = pageCount
        self.pageSize = pageSize
        self.packagePath = packagePath
        self.coverThumbnailPath = coverThumbnailPath
        self.rev = rev
    }

    /// Entry for a package's manifest. `packagePath` is the package directory name under the Notebooks root.
    public init(manifest: Manifest, packagePath: String, folderID: FolderID? = nil, coverThumbnailPath: String? = nil) {
        let n = manifest.notebook
        self.init(
            id: n.id, title: n.title, folderID: folderID, cover: n.cover, paper: n.paper, theme: n.theme,
            createdAt: n.createdAt, modifiedAt: n.modifiedAt, pageCount: n.pages.count, pageSize: n.pageSize,
            packagePath: packagePath, coverThumbnailPath: coverThumbnailPath, rev: n.rev
        )
    }

    /// Copies the manifest's notebook fields (title, cover, paper, theme, dates, page count/size, rev).
    public mutating func update(from manifest: Manifest) {
        let n = manifest.notebook
        title = n.title
        cover = n.cover
        paper = n.paper
        theme = n.theme
        createdAt = n.createdAt
        modifiedAt = n.modifiedAt
        pageCount = n.pages.count
        pageSize = n.pageSize
        rev = n.rev
    }
}

/// Hand-written so dates are Unix milliseconds (like the manifest) and decoding stays a flat, single pass.
/// Unknown keys are ignored; optional keys may be absent.
extension LibraryEntry: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, title, folderID, cover, paper, theme, createdAt, modifiedAt, pageCount, pageWidth, pageHeight
        case packagePath, coverThumbnailPath, rev
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(NotebookID.self, forKey: .id),
            title: c.decode(String.self, forKey: .title),
            folderID: c.decodeIfPresent(FolderID.self, forKey: .folderID),
            cover: c.decode(CoverColor.self, forKey: .cover),
            paper: c.decode(PaperStyle.self, forKey: .paper),
            theme: c.decode(PaperTheme.self, forKey: .theme),
            createdAt: Date(libraryMilliseconds: c.decode(Int64.self, forKey: .createdAt)),
            modifiedAt: Date(libraryMilliseconds: c.decode(Int64.self, forKey: .modifiedAt)),
            pageCount: c.decode(Int.self, forKey: .pageCount),
            pageSize: CGSize(width: c.decode(Double.self, forKey: .pageWidth), height: c.decode(Double.self, forKey: .pageHeight)),
            packagePath: c.decode(String.self, forKey: .packagePath),
            coverThumbnailPath: c.decodeIfPresent(String.self, forKey: .coverThumbnailPath),
            rev: c.decodeIfPresent(UInt64.self, forKey: .rev) ?? 0
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(folderID, forKey: .folderID)
        try c.encode(cover, forKey: .cover)
        try c.encode(paper, forKey: .paper)
        try c.encode(theme, forKey: .theme)
        try c.encode(createdAt.libraryMilliseconds, forKey: .createdAt)
        try c.encode(modifiedAt.libraryMilliseconds, forKey: .modifiedAt)
        try c.encode(pageCount, forKey: .pageCount)
        try c.encode(Double(pageSize.width), forKey: .pageWidth)
        try c.encode(Double(pageSize.height), forKey: .pageHeight)
        try c.encode(packagePath, forKey: .packagePath)
        try c.encodeIfPresent(coverThumbnailPath, forKey: .coverThumbnailPath)
        try c.encode(rev, forKey: .rev)
    }
}

/// A folder, nested to any depth (#117); a notebook is in at most one.
public struct LibraryFolder: Hashable, Sendable, Codable, Identifiable {
    /// Stable identity.
    public let id: FolderID
    /// Display name.
    public var name: String
    /// The folder it sits in; `nil` = top level.
    public var parentID: FolderID?

    /// Creates a folder.
    public init(id: FolderID = FolderID(), name: String, parentID: FolderID? = nil) {
        self.id = id
        self.name = name
        self.parentID = parentID
    }
}

public extension Collection<LibraryFolder> {
    /// Folders directly in `parent` (`nil` = top level), display order. A folder whose parent is missing
    /// counts as top level, so a damaged index never hides it.
    func children(of parent: FolderID?) -> [LibraryFolder] {
        guard let parent else {
            let ids = Set(map(\.id))
            return filter { $0.parentID.map { !ids.contains($0) } ?? true }
        }
        return filter { $0.parentID == parent }
    }

    /// `folder` and every folder nested in it.
    func subtree(of folder: FolderID) -> Set<FolderID> {
        var result: Set<FolderID> = [folder]
        var frontier = [folder]
        while let next = frontier.popLast() {
            for child in self where child.parentID == next && result.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return result
    }

    /// Top-level folder first, `folder` last; empty if `folder` is unknown.
    func path(to folder: FolderID) -> [LibraryFolder] {
        var path: [LibraryFolder] = []
        var current: FolderID? = folder
        while let id = current, let item = first(where: { $0.id == id }), !path.contains(item) {
            path.insert(item, at: 0)
            current = item.parentID
        }
        return path
    }
}

/// A notebook moved to `Library/Trash/`, purged ``LibraryStore/trashRetention`` after ``trashedAt``.
public struct TrashedNotebook: Hashable, Sendable, Identifiable {
    /// The entry as it was in the library (restored as-is, folder permitting).
    public var entry: LibraryEntry
    /// When it was deleted.
    public var trashedAt: Date

    /// Notebook ID.
    public var id: NotebookID {
        entry.id
    }

    /// Creates trash metadata.
    public init(entry: LibraryEntry, trashedAt: Date) {
        self.entry = entry
        self.trashedAt = trashedAt
    }
}

extension TrashedNotebook: Codable {
    private enum CodingKeys: String, CodingKey { case entry, trashedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            entry: c.decode(LibraryEntry.self, forKey: .entry),
            trashedAt: Date(libraryMilliseconds: c.decode(Int64.self, forKey: .trashedAt))
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry, forKey: .entry)
        try c.encode(trashedAt.libraryMilliseconds, forKey: .trashedAt)
    }
}

extension Date {
    /// Milliseconds since 1970, rounded (index and manifest precision).
    var libraryMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }

    init(libraryMilliseconds ms: Int64) {
        self.init(timeIntervalSince1970: Double(ms) / 1000)
    }
}
