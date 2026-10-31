import Document
import Foundation
import InkModel
import Library
import os

/// What this device knows of the sync folder (#225): `Application Support/Library/sync-state.json`, beside
/// `index.json`. Every op it has applied, merged (winning stamp and value per field and page), plus `local`
/// markers: what the library held at the last pull or push. A pull writes a merged value into the library
/// only where the library still holds its marker (otherwise the device changed it since, and its own push
/// will win); a push sends whatever differs from its marker.
///
/// Missing, damaged, newer, or about another folder or device ID: empty, so the next pull re-reads every log
/// and the next push re-sends everything the library has (never less).
public struct SyncState: Hashable, Sendable {
    public static let formatVersion = 1
    public static let fileName = "sync-state.json"

    /// The sync folder this state describes (its path).
    public var folder: String
    public var deviceId: String
    /// Lamport clock: max of every clock seen; the next op takes `clock + 1`.
    public var clock: UInt64 = 0
    /// Seq of the next log entry this device writes.
    public var nextSeq: UInt64 = 1
    /// Device → last log seq applied (this device's own: last written).
    public var applied: [String: UInt64] = [:]
    public var notebooks: [NotebookID: NotebookRecord] = [:]
    public var folders: [FolderID: FolderRecord] = [:]
    /// Notebooks with merged changes not written yet because an editor had them open.
    public var deferred: Set<NotebookID> = []
    /// Pages whose ink was replaced by another device's version, until Keep mine or dismissed.
    public var conflicts: [Conflict] = []
    /// This device's blobs (folder paths) no longer referenced, and since when (GC).
    public var garbage: [String: Garbage] = [:]

    public init(folder: String, deviceId: String) {
        self.folder = folder
        self.deviceId = deviceId
    }

    /// Takes the next Lamport clock.
    mutating func tick() -> UInt64 {
        clock += 1
        return clock
    }

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "sync")

    /// The state at `url` for `folder` and `deviceId`; empty if missing, unreadable, or for another folder.
    public static func load(from url: URL, folder: String, deviceId: String) -> SyncState {
        guard let data = try? Data(contentsOf: url) else { return SyncState(folder: folder, deviceId: deviceId) }
        guard let state = SyncJSON.decode(SyncState.self, from: data) else {
            log.error("sync state unreadable: starting over")
            return SyncState(folder: folder, deviceId: deviceId)
        }
        return state.folder == folder && state.deviceId == deviceId ? state : SyncState(folder: folder, deviceId: deviceId)
    }

    /// Writes atomically.
    public func save(to url: URL) throws(SyncError) {
        let data = try SyncJSON.encode(self)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SyncError(error)
        }
    }
}

/// A last-writer-wins value: the winning stamp and value, and `local`, the value the library held at the
/// last pull or push (`nil`: unknown, e.g. after a state reset: the library's value is sent again).
public struct Field: Hashable, Sendable, Codable {
    public var stamp: Stamp
    public var value: JSONValue
    public var local: JSONValue?

    /// The library has something to receive.
    var isPending: Bool {
        local != value
    }
}

/// One notebook as merged from every log.
public struct NotebookRecord: Hashable, Sendable {
    /// ``NotebookField`` raw value → field.
    public var fields: [String: Field] = [:]
    public var pages: [PageID: PageRecord] = [:]
    public var cover: CoverRecord?
    /// Assets in the folder, and those copied into the local package.
    public var assets: Set<SyncAsset> = []
    public var localAssets: Set<SyncAsset> = []
    public var tombstone: Stamp?
    /// The library has the notebook (as of the last pull or push).
    public var materialised = false
    /// Manifest `rev` the last push read; a push re-reads a manifest only when the index's `rev` moved.
    public var localRev: UInt64?
    /// Latest `at` of another device's ops (the notebook's modified date once written).
    public var modifiedAt: Date?
    /// Devices whose ops are merged but not written to the library yet ("Updated from iPhone").
    public var from: Set<String> = []

    public init() {}

    subscript(field: NotebookField) -> Field? {
        get { fields[field.rawValue] }
        set { fields[field.rawValue] = newValue }
    }

    /// Markers take the merged values (`folder` and `trashed`: as they apply): written, or deliberately not
    /// (the library's own change, which the next push sends).
    mutating func settle(_ fields: [NotebookField]) {
        for field in fields {
            let value = field == .folder || field == .trashed ? effective(field) : self[field]?.value
            self[field]?.local = value
        }
    }

    /// Latest stamp of anything but the tombstone.
    var latest: Stamp? {
        let stamps = fields.values.map(\.stamp) + pages.values.map(\.stamp) + [cover?.stamp].compactMap(\.self)
        return stamps.max()
    }

    /// Deleted: a tombstone newer than every other op.
    public var isDeleted: Bool {
        guard let tombstone else { return false }
        return latest.map { tombstone > $0 } ?? true
    }

    /// A field's value as it applies: after a tombstone that a later op overrode, `folder` and `trashed`
    /// written before the tombstone don't count (the notebook comes back to the root, out of the trash).
    func effective(_ field: NotebookField) -> JSONValue? {
        guard let f = self[field] else { return nil }
        if let tombstone, field == .folder || field == .trashed, f.stamp < tombstone {
            return field == .folder ? .null : .bool(false)
        }
        return f.value
    }

    var isTrashed: Bool {
        effective(.trashed) == .bool(true)
    }

    var folder: FolderID? {
        effective(.folder)?.folderID
    }

    /// The library has something to receive.
    var isPending: Bool {
        if isDeleted {
            return materialised
        }
        let library: Set<String> = [NotebookField.folder.rawValue, NotebookField.trashed.rawValue]
        return !fields.isEmpty && (!materialised || fields.contains { !library.contains($0.key) && $0.value.isPending }
            || [NotebookField.folder, .trashed].contains { f in self[f].map { $0.local != effective(f) } ?? false }
            || pages.values.contains { $0.isPending } || (cover?.isPending ?? false) || !assets.isSubset(of: localAssets))
    }
}

/// One page as merged: the winning `pageSet` or `pageRemove`.
public struct PageRecord: Hashable, Sendable, Codable {
    public var stamp: Stamp
    /// `base` of the winning `pageSet`.
    public var base: UInt64
    /// Strokes blob name (`nil`: no ink).
    public var blob: String?
    public var meta: PageMeta
    public var removed: Bool
    /// The version in the local package, if any.
    public var local: LocalPage?
    /// The blob this device showed before a `pageSet` written without seeing it replaced it: becomes a
    /// ``Conflict`` once the replacement is written.
    public var replaced: String?

    var isPending: Bool {
        removed ? local != nil : local?.stamp != stamp
    }
}

/// A page version in the local package: its stamp and blob, and the manifest page `rev` it was written or
/// sent at (a different `rev` now means the device has edited it since).
public struct LocalPage: Hashable, Sendable, Codable {
    public var stamp: Stamp
    public var rev: UInt64
    public var blob: String?
}

/// The cover as merged, and the local `thumbs/cover.heic` as last written or sent.
public struct CoverRecord: Hashable, Sendable, Codable {
    public var stamp: Stamp
    public var blob: String
    public var localStamp: Stamp?
    public var local: FileStamp?

    var isPending: Bool {
        localStamp != stamp
    }

    /// The merged cover counts as received (written, or the library's own newer one kept).
    mutating func settle() {
        localStamp = stamp
    }
}

/// One folder as merged: fields `name`, `parent`, `removed`.
public struct FolderRecord: Hashable, Sendable, Codable {
    public var fields: [String: Field] = [:]

    var isRemoved: Bool {
        fields["removed"]?.value == .bool(true)
    }

    var isPending: Bool {
        fields.values.contains { $0.isPending }
    }
}

/// A page whose ink this device showed was replaced by another device's version (#225 conflict pill):
/// `mine` is the replaced version's blob, still in the folder, for Keep mine.
public struct Conflict: Hashable, Sendable, Codable {
    public var notebook: NotebookID
    public var page: PageID
    public var theirs: String
    public var mine: String
    /// The device whose version replaced it.
    public var device: String
    public var since: Date
}

/// A blob of this device no longer referenced: deleted once ``SyncEngine/gcDelay`` has passed and every
/// active device has read as far as this device had (`acks`) when it noticed.
public struct Garbage: Hashable, Sendable, Codable {
    public var since: Date
    public var acks: [String: UInt64]
}

/// A file's modification date and size.
/// A local file's date and size, the marker for the cover. Dates compare at millisecond precision: the state
/// file stores them as milliseconds, and a finer comparison re-sent every cover after each launch.
public struct FileStamp: Hashable, Sendable, Codable {
    public var modified: Date
    public var size: Int64

    public init(modified: Date, size: Int64) {
        self.modified = modified
        self.size = size
    }

    /// The regular file at `url`; `nil` if missing.
    static func of(_ url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
        return FileStamp(modified: modified, size: Int64(values.fileSize ?? 0))
    }

    private var milliseconds: Int64 {
        Int64((modified.timeIntervalSince1970 * 1000).rounded())
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.milliseconds == rhs.milliseconds && lhs.size == rhs.size
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(milliseconds)
        hasher.combine(size)
    }
}

// MARK: Codable (ID-keyed maps as JSON objects)

extension SyncState: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, folder, deviceId, clock, nextSeq, applied, notebooks, folders, deferred, conflicts, garbage
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version == Self.formatVersion else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c, debugDescription: "formatVersion \(version)")
        }
        folder = try c.decode(String.self, forKey: .folder)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        clock = try c.decode(UInt64.self, forKey: .clock)
        nextSeq = try c.decode(UInt64.self, forKey: .nextSeq)
        applied = try c.decode([String: UInt64].self, forKey: .applied)
        notebooks = try c.decode([String: NotebookRecord].self, forKey: .notebooks).typedKeys()
        folders = try c.decode([String: FolderRecord].self, forKey: .folders).typedKeys()
        deferred = try Set(c.decode([NotebookID].self, forKey: .deferred))
        conflicts = try c.decode([Conflict].self, forKey: .conflicts)
        garbage = try c.decode([String: Garbage].self, forKey: .garbage)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .formatVersion)
        try c.encode(folder, forKey: .folder)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(clock, forKey: .clock)
        try c.encode(nextSeq, forKey: .nextSeq)
        try c.encode(applied, forKey: .applied)
        try c.encode(notebooks.stringKeys(), forKey: .notebooks)
        try c.encode(folders.stringKeys(), forKey: .folders)
        try c.encode(deferred.sorted(), forKey: .deferred)
        try c.encode(conflicts, forKey: .conflicts)
        try c.encode(garbage, forKey: .garbage)
    }
}

extension NotebookRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case fields, pages, cover, assets, localAssets, tombstone, materialised, localRev, modifiedAt, from
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fields = try c.decode([String: Field].self, forKey: .fields)
        pages = try c.decode([String: PageRecord].self, forKey: .pages).typedKeys()
        cover = try c.decodeIfPresent(CoverRecord.self, forKey: .cover)
        assets = try Set(c.decode([SyncAsset].self, forKey: .assets))
        localAssets = try Set(c.decode([SyncAsset].self, forKey: .localAssets))
        tombstone = try c.decodeIfPresent(Stamp.self, forKey: .tombstone)
        materialised = try c.decode(Bool.self, forKey: .materialised)
        localRev = try c.decodeIfPresent(UInt64.self, forKey: .localRev)
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt)
        from = try Set(c.decode([String].self, forKey: .from))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fields, forKey: .fields)
        try c.encode(pages.stringKeys(), forKey: .pages)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encode(assets.sorted(), forKey: .assets)
        try c.encode(localAssets.sorted(), forKey: .localAssets)
        try c.encodeIfPresent(tombstone, forKey: .tombstone)
        try c.encode(materialised, forKey: .materialised)
        try c.encodeIfPresent(localRev, forKey: .localRev)
        try c.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try c.encode(from.sorted(), forKey: .from)
    }
}

private extension Dictionary {
    func stringKeys<Tag>() -> [String: Value] where Key == TypedID<Tag> {
        [String: Value](uniqueKeysWithValues: map { ($0.key.description, $0.value) })
    }
}

private extension Dictionary where Key == String {
    func typedKeys<Tag>() throws -> [TypedID<Tag>: Value] {
        var result: [TypedID<Tag>: Value] = [:]
        for (key, value) in self {
            guard let id = TypedID<Tag>(uuidString: key) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Bad ID \(key)"))
            }
            result[id] = value
        }
        return result
    }
}
