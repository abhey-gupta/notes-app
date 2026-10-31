import Document
import Foundation
import InkModel
import Library

/// When an op happened, as all devices order it: Lamport `clock` (max seen + 1), ties broken by `device`.
/// Later stamp wins, per field and per page.
public struct Stamp: Hashable, Sendable, Codable, Comparable {
    public var clock: UInt64
    public var device: String

    public init(clock: UInt64, device: String) {
        self.clock = clock
        self.device = device
    }

    public static func < (lhs: Stamp, rhs: Stamp) -> Bool {
        lhs.clock != rhs.clock ? lhs.clock < rhs.clock : lhs.device < rhs.device
    }
}

/// One file in `log/<device>/`: ops a push wrote, in clock order. Written once, never modified.
public struct LogEntry: Hashable, Sendable, Codable {
    public var seq: UInt64
    public var device: String
    public var writtenAt: Date
    public var ops: [SyncOp]

    public init(seq: UInt64, device: String, writtenAt: Date, ops: [SyncOp]) {
        self.seq = seq
        self.device = device
        self.writtenAt = writtenAt
        self.ops = ops
    }
}

/// An immutable photo or PDF in a package (`images/<name>`, `backgrounds/<name>`): synced once, by name.
public struct SyncAsset: Hashable, Sendable, Codable, Comparable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case images
        case backgrounds
    }

    public var kind: Kind
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Package-relative path.
    var path: String {
        "\(kind.rawValue)/\(name)"
    }

    public static func < (lhs: SyncAsset, rhs: SyncAsset) -> Bool {
        lhs.path < rhs.path
    }
}

/// A page's manifest entry without its `rev` (the receiving device keeps its own).
public struct PageMeta: Hashable, Sendable, Codable {
    public var template: PageTemplate
    public var background: PageBackground
    public var extra: [String: JSONValue]

    public init(template: PageTemplate, background: PageBackground = .template, extra: [String: JSONValue] = [:]) {
        self.template = template
        self.background = background
        self.extra = extra
    }

    init(_ entry: PageEntry) {
        self.init(template: entry.template, background: entry.background, extra: entry.extra)
    }

    func entry(id: PageID, rev: UInt64) -> PageEntry {
        PageEntry(id: id, template: template, background: background, rev: rev, extra: extra)
    }
}

/// One change, stamped. JSON is flat with an `"op"` discriminator:
/// `{"op": "pageSet", "clock": 42, "at": <ms>, "notebook": "…", "page": "…", "base": 41, "entry": {…}, "strokes": "…"}`.
public struct SyncOp: Hashable, Sendable {
    /// Lamport clock; with the log entry's device, the op's ``Stamp``.
    public var clock: UInt64
    /// Wall time on the writing device (shown, never compared).
    public var at: Date
    public var change: SyncChange

    public init(clock: UInt64, at: Date, _ change: SyncChange) {
        self.clock = clock
        self.at = at
        self.change = change
    }
}

/// What an op does. Notebook and folder fields are last-writer-wins per field, pages per page.
public enum SyncChange: Hashable, Sendable {
    /// Sets notebook fields (``NotebookField``), each taking this op's stamp.
    case notebookSet(NotebookID, fields: [String: JSONValue])
    /// A page's content: `strokes` is a blob name in `blobs/<nb>/pages/<page>/` (`nil`: no ink). `base` is
    /// the clock of the page version the writer edited (0 for a new page): an op whose base isn't the clock
    /// the reader has applied was written without seeing it (a conflict, if both have ink).
    case pageSet(NotebookID, page: PageID, base: UInt64, entry: PageMeta, strokes: String?)
    case pageRemove(NotebookID, page: PageID)
    /// `blob` in `blobs/<nb>/cover/`.
    case coverSet(NotebookID, blob: String)
    case assetAdd(NotebookID, SyncAsset)
    /// `notebookTrash`, `notebookRestore`, `notebookDelete`.
    case lifecycle(NotebookID, Lifecycle)
    /// Folder fields `name` (string) and `parent` (folder ID string or null).
    case folderSet(FolderID, fields: [String: JSONValue])
    case folderRemove(FolderID)
    /// An op kind from a newer build: skipped (never fails the entry).
    case unknown(String)

    /// Trash state; the raw value is the op's JSON name.
    public enum Lifecycle: String, Hashable, Sendable {
        case trash = "notebookTrash"
        case restore = "notebookRestore"
        /// Tombstone (trash purged): wins over everything older; a later op brings the notebook back to the root.
        case delete = "notebookDelete"
    }

    /// The notebook it changes, if any.
    public var notebook: NotebookID? {
        switch self {
        case let .notebookSet(id, _), let .pageSet(id, _, _, _, _), let .pageRemove(id, _), let .coverSet(id, _),
             let .assetAdd(id, _), let .lifecycle(id, _):
            id
        case .folderSet, .folderRemove, .unknown:
            nil
        }
    }
}

extension SyncOp: Codable {
    private enum Key: String, CodingKey {
        case op, clock, at, notebook, page, base, entry, strokes, blob, kind, name, folder, fields
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        clock = try c.decode(UInt64.self, forKey: .clock)
        at = try c.decode(Date.self, forKey: .at)
        let op = try c.decode(String.self, forKey: .op)
        func notebook() throws -> NotebookID {
            try c.decode(NotebookID.self, forKey: .notebook)
        }
        if let lifecycle = SyncChange.Lifecycle(rawValue: op) {
            change = try .lifecycle(notebook(), lifecycle)
            return
        }
        switch op {
        case "notebookSet":
            change = try .notebookSet(notebook(), fields: c.decode([String: JSONValue].self, forKey: .fields))
        case "pageSet":
            change = try .pageSet(
                notebook(), page: c.decode(PageID.self, forKey: .page), base: c.decode(UInt64.self, forKey: .base),
                entry: c.decode(PageMeta.self, forKey: .entry), strokes: c.decodeIfPresent(String.self, forKey: .strokes)
            )
        case "pageRemove":
            change = try .pageRemove(notebook(), page: c.decode(PageID.self, forKey: .page))
        case "coverSet":
            change = try .coverSet(notebook(), blob: c.decode(String.self, forKey: .blob))
        case "assetAdd":
            let asset = try SyncAsset(kind: c.decode(SyncAsset.Kind.self, forKey: .kind), name: c.decode(String.self, forKey: .name))
            change = try .assetAdd(notebook(), asset)
        case "folderSet":
            change = try .folderSet(c.decode(FolderID.self, forKey: .folder), fields: c.decode([String: JSONValue].self, forKey: .fields))
        case "folderRemove":
            change = try .folderRemove(c.decode(FolderID.self, forKey: .folder))
        default:
            change = .unknown(op)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(clock, forKey: .clock)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(change.notebook, forKey: .notebook)
        switch change {
        case let .notebookSet(_, fields):
            try c.encode("notebookSet", forKey: .op)
            try c.encode(fields, forKey: .fields)
        case let .pageSet(_, page, base, entry, strokes):
            try c.encode("pageSet", forKey: .op)
            try c.encode(page, forKey: .page)
            try c.encode(base, forKey: .base)
            try c.encode(entry, forKey: .entry)
            try c.encodeIfPresent(strokes, forKey: .strokes)
        case let .pageRemove(_, page):
            try c.encode("pageRemove", forKey: .op)
            try c.encode(page, forKey: .page)
        case let .coverSet(_, blob):
            try c.encode("coverSet", forKey: .op)
            try c.encode(blob, forKey: .blob)
        case let .assetAdd(_, asset):
            try c.encode("assetAdd", forKey: .op)
            try c.encode(asset.kind, forKey: .kind)
            try c.encode(asset.name, forKey: .name)
        case let .lifecycle(_, lifecycle):
            try c.encode(lifecycle.rawValue, forKey: .op)
        case let .folderSet(id, fields):
            try c.encode("folderSet", forKey: .op)
            try c.encode(id, forKey: .folder)
            try c.encode(fields, forKey: .fields)
        case let .folderRemove(id):
            try c.encode("folderRemove", forKey: .op)
            try c.encode(id, forKey: .folder)
        case let .unknown(op):
            try c.encode(op, forKey: .op)
        }
    }
}

/// The notebook fields a `notebookSet` carries, as JSON values. `pages` is the page order (one field: the
/// last reorder wins whole); `folder` lives in the library index, the rest in `manifest.json`.
public enum NotebookField: String, CaseIterable, Sendable {
    case title, folder, cover, paper, theme, keepsExactColors, pageSize, leftExtension, createdAt, extra, pages
    /// Not in a `notebookSet`: `notebookTrash`/`notebookRestore` (``SyncChange/Lifecycle``) set it.
    case trashed

    /// Fields read from the manifest (``values(of:)``).
    static let manifestFields: [NotebookField] = [
        .title, .cover, .paper, .theme, .keepsExactColors, .pageSize, .leftExtension, .createdAt, .extra, .pages,
    ]

    /// A manifest's field values, canonical (as they read back from JSON).
    static func values(of manifest: Manifest) -> [NotebookField: JSONValue] {
        let n = manifest.notebook
        return [
            .title: .string(n.title),
            .cover: .string(n.cover.rawValue),
            .paper: .string(n.paper.rawValue),
            .theme: .string(n.theme.rawValue),
            .keepsExactColors: .bool(n.keepsExactColors),
            .pageSize: .canonical(["width": Double(n.pageSize.width), "height": Double(n.pageSize.height)]),
            .leftExtension: .canonical(Double(n.leftExtension)),
            .createdAt: .integer(Int64((n.createdAt.timeIntervalSince1970 * 1000).rounded())),
            .extra: .canonical(manifest.extra),
            .pages: .array(n.pages.map { .string($0.description) }),
        ]
    }

    static func value(of folder: FolderID?) -> JSONValue {
        folder.map { .string($0.description) } ?? .null
    }

    /// A notebook built from synced values over `base` (the local one, or defaults for a new notebook), with
    /// `base`'s `rev` and dates; `nil` if a required value is missing (fields arrive before the notebook can
    /// be created).
    static func notebook(id: NotebookID, values: [NotebookField: JSONValue], base: Notebook?, pages: [PageID]) -> Notebook? {
        func value<T: Decodable>(_ field: NotebookField, _: T.Type) -> T? {
            values[field].flatMap { $0.decoded(T.self) }
        }
        struct Size: Decodable { var width: Double, height: Double }
        guard let title = value(.title, String.self) ?? base?.title,
              let cover = value(.cover, String.self).flatMap(CoverColor.init(rawValue:)) ?? base?.cover,
              let paper = value(.paper, String.self).flatMap(PaperStyle.init(rawValue:)) ?? base?.paper,
              let theme = value(.theme, String.self).flatMap(PaperTheme.init(rawValue:)) ?? base?.theme,
              let size = value(.pageSize, Size.self).map({ CGSize(width: $0.width, height: $0.height) }) ?? base?.pageSize,
              let created = value(.createdAt, Int64.self).map({ Date(timeIntervalSince1970: Double($0) / 1000) }) ?? base?.createdAt
        else { return nil }
        return Notebook(
            id: id, title: title, cover: cover, paper: paper, theme: theme,
            keepsExactColors: value(.keepsExactColors, Bool.self) ?? base?.keepsExactColors ?? false,
            pageSize: size, leftExtension: CGFloat(value(.leftExtension, Double.self) ?? base.map { Double($0.leftExtension) } ?? 0),
            pages: pages, createdAt: created, modifiedAt: base?.modifiedAt, rev: base?.rev ?? 0
        )
    }
}

extension JSONValue {
    /// `value` as it reads back from JSON (`595.0` is `.integer(595)`), so values compare equal whether
    /// they came from a manifest, a log entry or the state file.
    static func canonical(_ value: some Encodable) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .null
        }
        return decoded
    }

    /// The value as a `T`; `nil` if it isn't one.
    func decoded<T: Decodable>(_: T.Type) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Page IDs of a `pages` value.
    var pageIDs: [PageID]? {
        guard case let .array(items) = self else { return nil }
        return items.compactMap { item in
            guard case let .string(s) = item else { return nil }
            return PageID(uuidString: s)
        }
    }

    /// The folder of a `folder` / `parent` value (`null`: none).
    var folderID: FolderID? {
        guard case let .string(s) = self else { return nil }
        return FolderID(uuidString: s)
    }
}
