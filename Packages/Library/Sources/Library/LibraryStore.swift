import Document
import Foundation
import InkModel

/// The library: one index file over the notebook packages (ARCHITECTURE.md §8).
///
/// - `Application Support/Library/index.json`: ``LibraryIndex``, rewritten atomically on every change.
/// - `Documents/Notebooks/<id>.nb`: packages (source of truth for notebook fields).
/// - `Application Support/Library/Trash/<id>.nb`: deleted packages, purged after ``trashRetention``.
///
/// Launch: ``readIndex(at:byteLimit:)`` decodes the index synchronously for the first frame (a 1 000-entry
/// index is a few ms), and the result seeds the store (`preloaded`) so it is never read twice. A missing or
/// corrupt index is rebuilt from the packages' manifests by ``load(progress:)``, off the main thread, with
/// progressive snapshots; the corrupt file is kept as `index.corrupt.json`.
///
/// Every mutation writes package files first, then the index; if the index write fails the package change
/// is rolled back (create, delete, duplicate, restore) so the two never disagree about which notebooks
/// exist. Metadata edits (``updateNotebook(_:_:)``) write the manifest first: if the index write then
/// fails, the index is merely stale until the next ``didSave(_:)``/``refresh(_:)``.
public actor LibraryStore {
    /// Deleted notebooks are kept this long (30 days).
    public static let trashRetention: TimeInterval = 30 * 86400
    /// Default cap for the synchronous launch read: ~3 000 entries. Larger indexes load on the actor.
    public static let synchronousReadLimit = 1 << 20
    /// Manifests read per progressive snapshot during a rebuild.
    static let rebuildBatch = 32

    /// Where the index, packages and trash live.
    public nonisolated let locations: LibraryLocations
    let now: @Sendable () -> Date
    var index: LibraryIndex?
    var loading: Task<Void, Never>?
    var generation: UInt64 = 0

    /// Creates a store. No I/O.
    /// - Parameters:
    ///   - preloaded: Index already decoded by ``readIndex(at:byteLimit:)``; skips the store's own read.
    ///   - now: Clock for trash dates and duplicates (tests).
    public init(
        locations: LibraryLocations = .standard,
        preloaded: LibraryIndex? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locations = locations
        index = preloaded
        self.now = now
    }

    // MARK: Launch

    /// Reads and decodes `index.json` on the calling thread, for the first frame.
    /// - Returns: `nil` if the index is missing, unreadable, corrupt, or larger than `byteLimit`
    ///   (then ``load(progress:)`` reads or rebuilds it off the main thread).
    public nonisolated static func readIndex(at locations: LibraryLocations, byteLimit: Int = synchronousReadLimit) -> LibraryIndex? {
        guard let data = try? Data(contentsOf: locations.indexURL), data.count <= byteLimit else { return nil }
        return try? LibraryIndex.decode(data)
    }

    /// Loads the index if it isn't yet: reads `index.json`, or rebuilds it from the packages, reporting
    /// partial snapshots (`isComplete == false`) every few manifests. Concurrent callers share one load.
    public func load(progress: (@Sendable (LibrarySnapshot) async -> Void)? = nil) async -> LibrarySnapshot {
        if index == nil, loading == nil {
            loading = Task { await self.performLoad(progress: progress) }
        }
        if let loading {
            await loading.value
        }
        return await snapshot()
    }

    /// Re-scans every package and rewrites the index, keeping folders, folder assignments and trash.
    public func rebuild(progress: (@Sendable (LibrarySnapshot) async -> Void)? = nil) async -> LibrarySnapshot {
        let previous = await loadedIndex()
        index = nil
        let task = Task { await self.performRebuild(keeping: previous, progress: progress) }
        loading = task
        await task.value
        return await snapshot()
    }

    /// Current state (loads first if needed).
    public func snapshot() async -> LibrarySnapshot {
        let index = await loadedIndex()
        return LibrarySnapshot(index: index, generation: generation)
    }

    // MARK: Notebooks

    /// Edits notebook metadata in the package manifest (bumping its `modifiedAt`), then the index entry.
    @discardableResult
    public func updateNotebook(_ id: NotebookID, _ change: @Sendable (inout Notebook) -> Void) async throws(LibraryError) -> LibraryEntry {
        var next = await loadedIndex()
        let i = try Self.position(of: id, in: next)
        var package: NotebookPackage
        do {
            package = try NotebookPackage.open(at: locations.packageURL(for: next.notebooks[i]))
            try package.updateNotebook(change)
        } catch {
            throw .document(error)
        }
        next.notebooks[i].update(from: package.manifest)
        let entry = next.notebooks[i]
        try commit(next)
        return entry
    }

    /// Renames a notebook. Blank titles become "Untitled".
    @discardableResult
    public func rename(_ id: NotebookID, to title: String) async throws(LibraryError) -> LibraryEntry {
        let title = Self.cleaned(title, fallback: "Untitled")
        return try await updateNotebook(id) { $0.title = title }
    }

    /// Files a notebook in `folder` (`nil` = no folder). Index only; the package is untouched.
    public func move(_ id: NotebookID, to folder: FolderID?) async throws(LibraryError) {
        var next = await loadedIndex()
        let i = try Self.position(of: id, in: next)
        try Self.check(folder, in: next)
        next.notebooks[i].folderID = folder
        try commit(next)
    }

    /// Moves a notebook's package to the trash. It is purged by ``purgeTrash(now:)`` after ``trashRetention``.
    public func delete(_ id: NotebookID) async throws(LibraryError) {
        var next = await loadedIndex()
        let entry = try next.notebooks.remove(at: Self.position(of: id, in: next))
        try trash([entry], in: &next)
    }

    /// Moves a trashed notebook back (to no folder if its folder is gone).
    @discardableResult
    public func restore(_ id: NotebookID) async throws(LibraryError) -> LibraryEntry {
        var next = await loadedIndex()
        guard let t = next.trash.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        var entry = next.trash.remove(at: t).entry
        if let folder = entry.folderID, !next.folders.contains(where: { $0.id == folder }) {
            entry.folderID = nil
        }
        let trashed = trashURL(for: entry)
        let destination = locations.packageURL(for: entry)
        do {
            try FileManager.default.createDirectory(at: locations.notebooksDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: trashed, to: destination)
        } catch {
            throw .io(trashed, reason: "\(error)")
        }
        next.notebooks.append(entry)
        do {
            try commit(next)
        } catch {
            try? FileManager.default.moveItem(at: destination, to: trashed)
            throw error
        }
        return entry
    }

    /// Deletes trashed notebooks older than ``trashRetention`` (index first, then files, so a crash leaves
    /// only orphaned files). Returns how many were purged.
    @discardableResult
    public func purgeTrash(now date: Date? = nil) async throws(LibraryError) -> Int {
        var next = await loadedIndex()
        let cutoff = (date ?? now()).addingTimeInterval(-Self.trashRetention)
        let expired = next.trash.filter { $0.trashedAt <= cutoff }
        guard !expired.isEmpty else { return 0 }
        next.trash.removeAll { $0.trashedAt <= cutoff }
        try commit(next)
        for item in expired {
            try? FileManager.default.removeItem(at: trashURL(for: item.entry))
        }
        return expired.count
    }

    /// Deletes a notebook now, from the library or its trash, package and all (another device purged it,
    /// #225). Index first, then files, so a crash leaves only orphaned files.
    public func purge(_ id: NotebookID) async throws(LibraryError) {
        var next = await loadedIndex()
        let url: URL
        if let i = next.notebooks.firstIndex(where: { $0.id == id }) {
            url = locations.packageURL(for: next.notebooks.remove(at: i))
        } else if let t = next.trash.firstIndex(where: { $0.id == id }) {
            url = trashURL(for: next.trash.remove(at: t).entry)
        } else {
            throw .notFound(id)
        }
        try commit(next)
        try? FileManager.default.removeItem(at: url)
    }

    /// Copies a notebook's package under a new ID, titled "<title> copy", in the same folder.
    @discardableResult
    public func duplicate(_ id: NotebookID) async throws(LibraryError) -> LibraryEntry {
        var next = await loadedIndex()
        let source = try next.notebooks[Self.position(of: id, in: next)]
        let sourceURL = locations.packageURL(for: source)
        let manifest: Manifest
        do {
            manifest = try NotebookPackage.readManifest(at: sourceURL)
        } catch {
            throw .document(error)
        }
        let n = manifest.notebook
        let date = now()
        let copy = Notebook(
            id: NotebookID(), title: Self.copyTitle(n.title, taken: Set(next.notebooks.map(\.title))), cover: n.cover,
            paper: n.paper, theme: n.theme, keepsExactColors: n.keepsExactColors, pageSize: n.pageSize, pages: n.pages,
            createdAt: date, modifiedAt: date
        )
        let copyManifest = Manifest(notebook: copy, entries: manifest.pages, extra: manifest.extra)
        let destination = NotebookPackage.url(for: copy.id, in: locations.notebooksDirectory)
        let staging = locations.notebooksDirectory.appending(path: ".\(UUID().uuidString).staging", directoryHint: .isDirectory)
        let fm = FileManager.default
        do {
            let data = try copyManifest.encoded()
            try fm.copyItem(at: sourceURL, to: staging)
            try data.write(to: staging.appending(path: "manifest.json"), options: .atomic)
            try fm.moveItem(at: staging, to: destination)
        } catch {
            try? fm.removeItem(at: staging)
            if let error = error as? DocumentError {
                throw .document(error)
            }
            throw .io(destination, reason: "\(error)")
        }
        let path = destination.lastPathComponent
        let entry = LibraryEntry(
            manifest: copyManifest, packagePath: path, folderID: source.folderID, coverThumbnailPath: coverThumbnailPath(forPackage: path)
        )
        next.notebooks.append(entry)
        do {
            try commit(next)
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
        return entry
    }

    /// Updates a notebook's entry after its package manifest was written elsewhere (`DocumentStore`
    /// checkpoint, page insert/delete): title, modified, page count… and whether `cover.heic` exists.
    /// Ignores manifests older than the entry (`rev`) and notebooks not in the library.
    public func didSave(_ manifest: Manifest) async throws(LibraryError) {
        var next = await loadedIndex()
        guard let i = next.notebooks.firstIndex(where: { $0.id == manifest.notebook.id }),
              manifest.notebook.rev >= next.notebooks[i].rev else { return }
        next.notebooks[i].update(from: manifest)
        next.notebooks[i].coverThumbnailPath = coverThumbnailPath(forPackage: next.notebooks[i].packagePath)
        guard next != index else { return }
        try commit(next)
    }

    /// Re-reads one notebook's manifest from disk into its entry.
    public func refresh(_ id: NotebookID) async throws(LibraryError) {
        let index = await loadedIndex()
        let entry = try index.notebooks[Self.position(of: id, in: index)]
        do {
            try await didSave(NotebookPackage.readManifest(at: locations.packageURL(for: entry)))
        } catch let error as LibraryError {
            throw error
        } catch let error as DocumentError {
            throw .document(error)
        } catch {
            throw .io(locations.packageURL(for: entry), reason: "\(error)")
        }
    }

    // MARK: Folders

    /// Adds a folder at the end, in `parent` (`nil` = top level). Blank names become "New Folder".
    @discardableResult
    public func createFolder(named name: String, in parent: FolderID? = nil) async throws(LibraryError) -> LibraryFolder {
        var next = await loadedIndex()
        try Self.check(parent, in: next)
        let folder = LibraryFolder(name: Self.cleaned(name, fallback: "New Folder"), parentID: parent)
        next.folders.append(folder)
        try commit(next)
        return folder
    }

    /// Renames a folder.
    public func renameFolder(_ id: FolderID, to name: String) async throws(LibraryError) {
        var next = await loadedIndex()
        guard let i = next.folders.firstIndex(where: { $0.id == id }) else { throw .unknownFolder(id) }
        next.folders[i].name = Self.cleaned(name, fallback: "New Folder")
        try commit(next)
    }

    /// Creates `folder` with its ID, or renames and moves the folder with that ID (sync, #225). Blank names
    /// become "New Folder"; a parent that would put the folder inside itself files it at the top level
    /// (two devices each moved one folder into the other: both end up valid).
    /// - Throws: ``LibraryError/unknownFolder(_:)`` if the parent isn't in the library.
    public func upsertFolder(_ folder: LibraryFolder) async throws(LibraryError) {
        var next = await loadedIndex()
        var folder = folder
        folder.name = Self.cleaned(folder.name, fallback: "New Folder")
        if let parent = folder.parentID {
            try Self.check(parent, in: next)
            if next.folders.subtree(of: folder.id).contains(parent) {
                folder.parentID = nil
            }
        }
        if let i = next.folders.firstIndex(where: { $0.id == folder.id }) {
            guard next.folders[i] != folder else { return }
            next.folders[i] = folder
        } else {
            next.folders.append(folder)
        }
        try commit(next)
    }

    /// Removes a folder, every folder nested in it, and their notebooks (to the trash, #117).
    public func deleteFolder(_ id: FolderID) async throws(LibraryError) {
        var next = await loadedIndex()
        guard next.folders.contains(where: { $0.id == id }) else { throw .unknownFolder(id) }
        let removed = next.folders.subtree(of: id)
        next.folders.removeAll { removed.contains($0.id) }
        let notebooks = next.notebooks.filter { $0.folderID.map(removed.contains) ?? false }
        next.notebooks.removeAll { $0.folderID.map(removed.contains) ?? false }
        try trash(notebooks, in: &next)
    }
}
