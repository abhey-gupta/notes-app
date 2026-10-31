import Document
import Foundation
import InkModel
import Library

/// A notebook package in the library, as a push sees it.
struct LocalNotebook: Sendable {
    var entry: LibraryEntry
    var trashed: Bool
    var packageURL: URL

    var id: NotebookID {
        entry.id
    }
}

/// A local file a push copies into the folder before its log entry.
struct Upload: Hashable, Sendable {
    var local: URL
    var path: String
    var bytes: Int64
}

/// What a push found changed in one notebook: its ops (clocks taken in order), the files they need, and the
/// library's values to record as the new local markers once the entry is written.
struct NotebookChanges: Sendable {
    var ops: [SyncOp] = []
    var uploads: [Upload] = []
    /// Pages sent, for progress ("Sending Physics · 3 pages").
    var pages = 0
    /// Current values of the fields compared (manifest fields only when the manifest was read).
    var values: [NotebookField: JSONValue] = [:]
    /// Manifest page `rev`s, when read.
    var pageRevs: [PageID: UInt64]?
    var assets: Set<SyncAsset> = []
    var cover: FileStamp?
    /// Manifest `rev` when the manifest was read.
    var manifestRev: UInt64?
}

/// Reads the library side of a push (#225): one index `rev` and one `stat` (cover) per notebook, and the
/// manifest only of notebooks whose `rev` moved since the last push, then diffs it against the state's local
/// markers: changed fields, pages whose `rev` or entry moved, removed pages, new assets, the cover.
enum LocalScan {
    /// Every notebook in `snapshot` and its trash.
    static func notebooks(in snapshot: LibrarySnapshot, locations: LibraryLocations) -> [LocalNotebook] {
        snapshot.notebooks.map { LocalNotebook(entry: $0, trashed: false, packageURL: locations.packageURL(for: $0)) }
            + snapshot.trash.map {
                LocalNotebook(
                    entry: $0.entry, trashed: true,
                    packageURL: locations.trashDirectory.appending(path: $0.entry.packagePath, directoryHint: .isDirectory)
                )
            }
    }

    /// One notebook's changes since its markers in `state`, with clocks taken from `state`. An unreadable
    /// manifest leaves its contents unsent (its folder and trash state still go).
    static func ops(for local: LocalNotebook, state: inout SyncState, now: Date) -> NotebookChanges {
        var scan = NotebookScan(local: local, record: state.notebooks[local.id], device: state.deviceId, now: now)
        var manifest: Manifest?
        if scan.record?.localRev != local.entry.rev || scan.record?.materialised != true {
            manifest = try? NotebookPackage.readManifest(at: local.packageURL)
        }
        scan.fields(manifest, state: &state)
        if let manifest {
            scan.assets(state: &state)
            scan.pages(manifest, state: &state)
        }
        scan.cover(state: &state)
        scan.trash(state: &state)
        return scan.changes
    }

    /// `images/*` and `backgrounds/*` of a package.
    static func assets(in package: URL) -> Set<SyncAsset> {
        var assets: Set<SyncAsset> = []
        for kind in SyncAsset.Kind.allCases {
            let directory = package.appending(path: kind.rawValue, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
            for name in names where !name.hasPrefix(".") {
                assets.insert(SyncAsset(kind: kind, name: name))
            }
        }
        return assets
    }

    /// Folder ops: new and changed folders (`name`, `parent` against their markers), and folders the library
    /// had at the last pull or push and no longer has.
    static func folderOps(_ folders: [LibraryFolder], state: inout SyncState, now: Date) -> [SyncOp] {
        var ops: [SyncOp] = []
        for folder in folders {
            let record = state.folders[folder.id]
            var fields: [String: JSONValue] = [:]
            let current: [String: JSONValue] = ["name": .string(folder.name), "parent": NotebookField.value(of: folder.parentID)]
            for (key, value) in current where record?.fields[key].map({ $0.local != value }) ?? true {
                fields[key] = value
            }
            if !fields.isEmpty {
                ops.append(SyncOp(clock: state.tick(), at: now, .folderSet(folder.id, fields: fields)))
            }
        }
        let present = Set(folders.map(\.id))
        for (id, record) in state.folders.sorted(by: { $0.key < $1.key })
            where !present.contains(id) && record.fields["name"]?.local != nil && record.fields["removed"]?.local != .bool(true)
        {
            ops.append(SyncOp(clock: state.tick(), at: now, .folderRemove(id)))
        }
        return ops
    }
}

/// One notebook's push diff, built step by step (``LocalScan/ops(for:state:now:)``).
private struct NotebookScan {
    let local: LocalNotebook
    let record: NotebookRecord?
    let device: String
    let now: Date
    var changes = NotebookChanges()

    private var id: NotebookID {
        local.id
    }

    private mutating func op(_ change: SyncChange, state: inout SyncState) {
        changes.ops.append(SyncOp(clock: state.tick(), at: now, change))
    }

    /// One `notebookSet` with the fields that differ from their markers (`folder` always compared).
    mutating func fields(_ manifest: Manifest?, state: inout SyncState) {
        changes.values[.folder] = NotebookField.value(of: local.entry.folderID)
        changes.values[.trashed] = .bool(local.trashed)
        var compared: [NotebookField: JSONValue] = [.folder: NotebookField.value(of: local.entry.folderID)]
        if let manifest {
            compared.merge(NotebookField.values(of: manifest)) { _, new in new }
            changes.manifestRev = manifest.notebook.rev
        }
        changes.values.merge(compared) { _, new in new }
        var fields: [String: JSONValue] = [:]
        for (field, value) in compared where record?[field].map({ $0.local != value }) ?? true {
            fields[field.rawValue] = value
        }
        if !fields.isEmpty {
            op(.notebookSet(id, fields: fields), state: &state)
        }
    }

    /// Assets the folder doesn't have yet.
    mutating func assets(state: inout SyncState) {
        changes.assets = LocalScan.assets(in: local.packageURL)
        for asset in changes.assets.sorted() where !(record?.assets.contains(asset) ?? false) {
            let file = local.packageURL.appending(path: asset.path)
            changes.uploads.append(Upload(local: file, path: SyncLayout.asset(asset, notebook: id), bytes: FileStamp.of(file)?.size ?? 0))
            op(.assetAdd(id, asset), state: &state)
        }
    }

    /// Pages whose `rev` (or, for a page showing the merged version, entry) moved; pages gone since sent.
    mutating func pages(_ manifest: Manifest, state: inout SyncState) {
        changes.pageRevs = Dictionary(manifest.pages.map { ($0.id, $0.rev) }, uniquingKeysWith: { first, _ in first })
        for entry in manifest.pages {
            let page = record?.pages[entry.id]
            let meta = PageMeta(entry)
            let edited = page?.local.map { $0.rev != entry.rev || ($0.stamp == page?.stamp && meta != page?.meta) } ?? true
            guard edited else { continue }
            let clock = state.tick()
            let file = local.packageURL.appending(path: "pages/\(entry.id).strokes")
            var blob: String?
            if let stamp = FileStamp.of(file) {
                let name = SyncLayout.blobName(clock: clock, device: device, ext: "strokes")
                changes.uploads.append(Upload(local: file, path: SyncLayout.strokes(name, notebook: id, page: entry.id), bytes: stamp.size))
                blob = name
            }
            // The version this edit was made on: the one the package holds (unknown after a state reset: the merged one).
            let base = page.map { $0.local?.stamp.clock ?? $0.stamp.clock } ?? 0
            changes.ops.append(SyncOp(clock: clock, at: now, .pageSet(id, page: entry.id, base: base, entry: meta, strokes: blob)))
            changes.pages += 1
        }
        let present = Set(manifest.notebook.pages)
        for (page, known) in (record?.pages ?? [:]).sorted(by: { $0.key < $1.key })
            where !known.removed && known.local != nil && !present.contains(page)
        {
            op(.pageRemove(id, page: page), state: &state)
        }
    }

    /// `thumbs/cover.heic` when its date or size moved.
    mutating func cover(state: inout SyncState) {
        let file = NotebookPackage.thumbnailsDirectory(in: local.packageURL).appending(path: "cover.heic")
        changes.cover = FileStamp.of(file)
        guard let cover = changes.cover, cover != record?.cover?.local else { return }
        let clock = state.tick()
        let name = SyncLayout.blobName(clock: clock, device: device, ext: "heic")
        changes.uploads.append(Upload(local: file, path: SyncLayout.cover(name, notebook: id), bytes: cover.size))
        changes.ops.append(SyncOp(clock: clock, at: now, .coverSet(id, blob: name)))
    }

    /// Trashed or restored since the marker.
    mutating func trash(state: inout SyncState) {
        guard (record?[.trashed]?.local ?? .bool(false)) != .bool(local.trashed) else { return }
        op(.lifecycle(id, local.trashed ? .trash : .restore), state: &state)
    }
}
