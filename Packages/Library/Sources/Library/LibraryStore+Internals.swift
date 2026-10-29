import Document
import Foundation
import InkModel

/// Loading, rebuild and commit plumbing for ``LibraryStore``.
extension LibraryStore {
    enum DiskIndex {
        case loaded(LibraryIndex)
        case missing
        case unreadable
    }

    func loadedIndex() async -> LibraryIndex {
        while true {
            if let index {
                return index
            }
            let task = loading ?? Task { await self.performLoad(progress: nil) }
            loading = task
            await task.value
        }
    }

    func performLoad(progress: (@Sendable (LibrarySnapshot) async -> Void)?) async {
        defer { loading = nil }
        switch readIndexFromDisk() {
        case let .loaded(index):
            adopt(index)
        case .missing:
            await performRebuild(keeping: nil, progress: progress)
        case .unreadable:
            let fm = FileManager.default
            try? fm.removeItem(at: locations.corruptIndexURL)
            try? fm.moveItem(at: locations.indexURL, to: locations.corruptIndexURL)
            await performRebuild(keeping: nil, progress: progress)
        }
    }

    func readIndexFromDisk() -> DiskIndex {
        let data: Data
        do {
            data = try Data(contentsOf: locations.indexURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
        guard let index = try? LibraryIndex.decode(data) else { return .unreadable }
        return .loaded(index)
    }

    /// Scans `Notebooks/*.nb` (and `Trash/*.nb` when there's no previous trash list), batch by batch.
    /// Unreadable manifests are skipped. Ends with ``index`` set, even if writing it fails.
    func performRebuild(keeping previous: LibraryIndex?, progress: (@Sendable (LibrarySnapshot) async -> Void)?) async {
        defer { loading = nil }
        let folders = previous?.folders ?? []
        let knownFolders = Set(folders.map(\.id))
        let assignments = Dictionary(
            (previous?.notebooks ?? []).compactMap { e in e.folderID.map { (e.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let urls = (try? NotebookPackage.packageURLs(in: locations.notebooksDirectory)) ?? []
        var entries: [LibraryEntry] = []
        entries.reserveCapacity(urls.count)
        for (n, url) in urls.enumerated() {
            if var entry = entry(forPackageAt: url) {
                entry.folderID = assignments[entry.id].flatMap { knownFolders.contains($0) ? $0 : nil }
                entries.append(entry)
            }
            if let progress, (n + 1) % Self.rebuildBatch == 0, n + 1 < urls.count {
                generation += 1
                await progress(LibrarySnapshot(
                    index: LibraryIndex(notebooks: entries, folders: folders),
                    generation: generation,
                    isComplete: false
                ))
            }
        }
        let trash = previous?.trash ?? scanTrash()
        let rebuilt = LibraryIndex(notebooks: entries, folders: folders, trash: trash)
        adopt(rebuilt)
        try? write(rebuilt)
    }

    func scanTrash() -> [TrashedNotebook] {
        let date = now()
        return ((try? NotebookPackage.packageURLs(in: locations.trashDirectory)) ?? []).compactMap { url in
            guard let manifest = try? NotebookPackage.readManifest(at: url) else { return nil }
            return TrashedNotebook(entry: LibraryEntry(manifest: manifest, packagePath: url.lastPathComponent), trashedAt: date)
        }
    }

    func entry(forPackageAt url: URL) -> LibraryEntry? {
        guard let manifest = try? NotebookPackage.readManifest(at: url) else { return nil }
        let path = url.lastPathComponent
        return LibraryEntry(manifest: manifest, packagePath: path, coverThumbnailPath: coverThumbnailPath(forPackage: path))
    }

    /// `<package>/thumbs/cover.heic` if it exists.
    func coverThumbnailPath(forPackage path: String) -> String? {
        let relative = "\(path)/thumbs/cover.heic"
        return FileManager.default.fileExists(atPath: locations.notebooksURL(relative).path(percentEncoded: false)) ? relative : nil
    }

    func trashURL(for entry: LibraryEntry) -> URL {
        locations.trashDirectory.appending(path: entry.packagePath, directoryHint: .isDirectory)
    }

    func adopt(_ next: LibraryIndex) {
        index = next
        generation += 1
    }

    /// Writes `next` (sorted), then adopts it. On failure nothing changes.
    func commit(_ next: LibraryIndex) throws(LibraryError) {
        var next = next
        next.sortNotebooks()
        try write(next)
        adopt(next)
    }

    func write(_ index: LibraryIndex) throws(LibraryError) {
        let data = try index.encoded()
        do {
            try FileManager.default.createDirectory(at: locations.libraryDirectory, withIntermediateDirectories: true)
            try data.write(to: locations.indexURL, options: .atomic)
        } catch {
            throw .io(locations.indexURL, reason: "\(error)")
        }
    }

    /// Moves `entries`' packages to the trash and commits `index` (from which the caller removed them) with
    /// their trash records; on failure, puts the packages back.
    func trash(_ entries: [LibraryEntry], in index: inout LibraryIndex) throws(LibraryError) {
        let fm = FileManager.default
        var moved: [(from: URL, to: URL)] = []
        func undo() {
            for move in moved {
                try? fm.moveItem(at: move.to, to: move.from)
            }
        }
        let date = now()
        for entry in entries {
            let source = locations.packageURL(for: entry)
            let trashed = trashURL(for: entry)
            do {
                try fm.createDirectory(at: locations.trashDirectory, withIntermediateDirectories: true)
                if fm.fileExists(atPath: trashed.path(percentEncoded: false)) {
                    try fm.removeItem(at: trashed)
                }
                if fm.fileExists(atPath: source.path(percentEncoded: false)) {
                    try fm.moveItem(at: source, to: trashed)
                    moved.append((source, trashed))
                }
            } catch {
                undo()
                throw .io(source, reason: "\(error)")
            }
            index.trash.append(TrashedNotebook(entry: entry, trashedAt: date))
        }
        do {
            try commit(index)
        } catch {
            undo()
            throw error
        }
    }

    static func position(of id: NotebookID, in index: LibraryIndex) throws(LibraryError) -> Int {
        guard let i = index.notebooks.firstIndex(where: { $0.id == id }) else { throw .notFound(id) }
        return i
    }

    static func check(_ folder: FolderID?, in index: LibraryIndex) throws(LibraryError) {
        if let folder, !index.folders.contains(where: { $0.id == folder }) {
            throw .unknownFolder(folder)
        }
    }

    static func cleaned(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// "Physics copy", then "Physics copy 2", "Physics copy 3"…
    static func copyTitle(_ title: String, taken: Set<String>) -> String {
        numbered("\(title) copy", taken: taken)
    }

    /// `base`, or `base 2`, `base 3`… : the first not in `taken`.
    static func numbered(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") {
            n += 1
        }
        return "\(base) \(n)"
    }
}
