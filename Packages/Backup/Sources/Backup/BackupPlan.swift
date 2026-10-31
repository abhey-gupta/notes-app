import Document
import Foundation
import InkModel
import Library

/// A notebook package in the library, as a run sees it (``LocalScan``).
public struct LocalNotebook: Sendable {
    /// What a read of the package found: only for notebooks ``BackupPlanner/needsInspection(_:state:remote:)``.
    public struct Contents: Sendable {
        public var manifest: Manifest
        /// Package-relative path → size, of the files a backup holds: `manifest.json`, `pages/*.strokes`,
        /// `images/*`, `backgrounds/*` (never journals, page thumbnails or migration backups).
        public var files: [String: Int64]

        public init(manifest: Manifest, files: [String: Int64]) {
            self.manifest = manifest
            self.files = files
        }
    }

    public var entry: LibraryEntry
    public var location: BackupLocation
    public var packageURL: URL
    /// `manifest.json`'s modification date; `nil` if the package can't be read (then it's left alone).
    public var manifestModified: Date?
    /// `thumbs/cover.heic`, if there is one.
    public var cover: FileStamp?
    public var contents: Contents?

    public init(
        entry: LibraryEntry, location: BackupLocation, packageURL: URL, manifestModified: Date?, cover: FileStamp? = nil,
        contents: Contents? = nil
    ) {
        self.entry = entry
        self.location = location
        self.packageURL = packageURL
        self.manifestModified = manifestModified
        self.cover = cover
        self.contents = contents
    }

    public var id: NotebookID {
        entry.id
    }
}

/// The packages in the backup folder, by ID.
public struct RemoteListing: Hashable, Sendable {
    public var notebooks: Set<NotebookID>
    public var trash: Set<NotebookID>

    public init(notebooks: Set<NotebookID> = [], trash: Set<NotebookID> = []) {
        self.notebooks = notebooks
        self.trash = trash
    }

    public func contains(_ id: NotebookID, at location: BackupLocation) -> Bool {
        location == .notebooks ? notebooks.contains(id) : trash.contains(id)
    }
}

/// One change to the backup folder. Paths are relative to it.
public enum BackupOperation: Hashable, Sendable {
    /// Copy a local file to `to` (replacing it).
    case copy(URL, to: String, bytes: Int64)
    /// Delete a file or package.
    case delete(String)
    /// Move a package (trash, restore).
    case move(String, to: String)
}

/// A run's work for one notebook: operations in order (move first, `manifest.json` last, so the folder never
/// has a manifest naming files it lacks), then the state to record once they succeed.
public struct NotebookPlan: Hashable, Sendable {
    public var id: NotebookID
    public var title: String
    public var operations: [BackupOperation]
    /// `nil`: no longer backed up (deleted from the folder).
    public var state: BackupState.Notebook?

    /// Bytes this plan copies.
    public var bytes: Int64 {
        operations.reduce(0) { sum, op in
            if case let .copy(_, _, bytes) = op {
                return sum + bytes
            }
            return sum
        }
    }
}

/// The incremental diff (#174), pure: library + previous ``BackupState`` + what the folder holds → per-notebook
/// operations. Per file: `manifest.json` when it changed, a page's stroke file when its `rev` moved,
/// immutable assets once, `cover.heic` when its date moved; remote stroke files of deleted pages go.
public enum BackupPlanner {
    /// Whether a run must read `notebook`'s manifest and files: new to the backup, gone from the folder, or
    /// its manifest changed since the copy.
    public static func needsInspection(_ notebook: LocalNotebook, state: BackupState, remote: RemoteListing) -> Bool {
        guard notebook.manifestModified != nil else { return false }
        guard let known = state.notebooks[notebook.id], remote.contains(notebook.id, at: known.location) else { return true }
        return known.manifestModified != notebook.manifestModified
    }

    /// Plans for every notebook that needs work, in `local` order, then deletions. `local` lists the library
    /// and its trash; a notebook in `state` but not in `local` was purged or removed: its package goes.
    public static func plan(local: [LocalNotebook], state: BackupState, remote: RemoteListing) -> [NotebookPlan] {
        var plans = local.compactMap { plan($0, state: state, remote: remote) }
        let ids = Set(local.map(\.id))
        for (id, known) in state.notebooks.sorted(by: { $0.key < $1.key }) where !ids.contains(id) {
            let present = remote.contains(id, at: known.location)
            plans.append(NotebookPlan(
                id: id, title: "", operations: present ? [.delete(BackupLayout.package(id, in: known.location))] : [], state: nil
            ))
        }
        return plans
    }

    static func plan(_ notebook: LocalNotebook, state: BackupState, remote: RemoteListing) -> NotebookPlan? {
        guard notebook.manifestModified != nil else { return nil }
        let id = notebook.id
        let known = state.notebooks[id]
        var operations: [BackupOperation] = []
        // What the folder holds: the known copy if it's there, else nothing (copy everything).
        var base = BackupState.Notebook.empty(at: notebook.location)
        if let known, remote.contains(id, at: known.location) {
            base = known
            if known.location != notebook.location {
                operations.append(.move(BackupLayout.package(id, in: known.location), to: BackupLayout.package(id, in: notebook.location)))
                base.location = notebook.location
            }
        }
        guard notebook.contents != nil || base.manifestModified != nil else { return nil }
        let package = BackupLayout.package(id, in: notebook.location)
        let copy = { (file: String, bytes: Int64) in
            BackupOperation.copy(notebook.packageURL.appending(path: file), to: "\(package)/\(file)", bytes: bytes)
        }
        var next = base
        if let contents = notebook.contents {
            operations += contentOperations(contents, base: base, next: &next, package: package, copy: copy)
            next.manifestModified = notebook.manifestModified
            next.bytes += notebook.cover?.size ?? 0
        } else {
            next.bytes = base.bytes - (base.cover?.size ?? 0) + (notebook.cover?.size ?? 0)
        }
        if notebook.cover != base.cover {
            operations.append(notebook.cover.map { copy("thumbs/cover.heic", $0.size) } ?? .delete("\(package)/thumbs/cover.heic"))
        }
        next.cover = notebook.cover
        if let contents = notebook.contents {
            operations.append(copy("manifest.json", contents.files["manifest.json"] ?? 0))
        }
        guard !operations.isEmpty || next != known else { return nil }
        return NotebookPlan(id: id, title: notebook.entry.title, operations: operations, state: next)
    }

    /// What a run records for a package the folder already holds file for file (a notebook just restored from
    /// it): the state after copying all of `notebook`, without copying anything. `location` is where the
    /// folder's copy sits. `nil` if the package wasn't inspected.
    public static func recorded(_ notebook: LocalNotebook, at location: BackupLocation) -> BackupState.Notebook? {
        guard let contents = notebook.contents else { return nil }
        var next = BackupState.Notebook.empty(at: location)
        _ = contentOperations(
            contents,
            base: next,
            next: &next,
            package: "",
            copy: { file, bytes in .copy(notebook.packageURL, to: file, bytes: bytes) }
        )
        next.manifestModified = notebook.manifestModified
        next.cover = notebook.cover
        next.bytes += notebook.cover?.size ?? 0
        return next
    }

    /// Stroke files whose page `rev` moved, assets not copied yet, and deletions of remote stroke files of
    /// pages that lost theirs; sets `next`'s strokes, assets, rev and bytes (without the cover).
    private static func contentOperations(
        _ contents: LocalNotebook.Contents,
        base: BackupState.Notebook,
        next: inout BackupState.Notebook,
        package: String,
        copy: (String, Int64) -> BackupOperation
    ) -> [BackupOperation] {
        var operations: [BackupOperation] = []
        var strokes: [PageID: UInt64] = [:]
        var bytes: Int64 = contents.files["manifest.json"] ?? 0
        for page in contents.manifest.pages {
            let file = "pages/\(page.id).strokes"
            guard let size = contents.files[file] else { continue }
            if base.strokes[page.id] != page.rev {
                operations.append(copy(file, size))
            }
            strokes[page.id] = page.rev
            bytes += size
        }
        for (file, size) in contents.files.sorted(by: { $0.key < $1.key }) where isAsset(file) {
            if !base.assets.contains(file) {
                operations.append(copy(file, size))
            }
            bytes += size
        }
        for page in base.strokes.keys.sorted() where strokes[page] == nil {
            operations.append(.delete("\(package)/pages/\(page).strokes"))
        }
        next.strokes = strokes
        next.assets = base.assets.union(contents.files.keys.filter(isAsset))
        next.rev = contents.manifest.notebook.rev
        next.bytes = bytes
        return operations
    }

    /// Immutable, by name: photos (#157) and imported PDFs (#119).
    static func isAsset(_ file: String) -> Bool {
        file.hasPrefix("images/") || file.hasPrefix("backgrounds/")
    }
}
