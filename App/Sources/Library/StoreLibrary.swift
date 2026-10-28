import Document
import Foundation
import InkModel
import Library
import Observation
import os
#if DEBUG || PERF_FIXTURES
    import FixtureGen
#endif

/// The real library: a main-actor mirror of `LibraryStore` (§8).
///
/// Launch: `init` decodes `index.json` synchronously (≈ 0.1 ms for a typical library, a few ms at 1 000
/// notebooks, skipped above 1 MB), so the first frame already shows the notebooks: no spinner, no empty
/// flash. If the index is missing, corrupt or huge, `start()` loads or rebuilds it off the main thread
/// after the first frame, applying progressive snapshots.
@MainActor
@Observable
final class StoreLibrary: LibraryModel {
    private(set) var notebooks: [NotebookSummary] = []
    private(set) var folders: [LibraryFolder] = []
    private(set) var isLoaded = false

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored private let locations: LibraryLocations
    @ObservationIgnored private var generation: UInt64 = 0
    /// Package path (relative to the notebooks directory) by notebook, from the last snapshot.
    @ObservationIgnored private var packagePaths: [NotebookID: String] = [:]
    /// When the editor last wrote a notebook's cover this launch; keeps the cover's cache key moving even
    /// when the index entry (and so `modifiedAt`) didn't change.
    @ObservationIgnored private var coverVersions: [NotebookID: Date] = [:]

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "library")

    init(locations: LibraryLocations = .standard) {
        let start = ContinuousClock.now
        let index = LibraryStore.readIndex(at: locations)
        self.locations = locations
        store = LibraryStore(locations: locations, preloaded: index)
        if let index {
            apply(LibrarySnapshot(index: index))
            isLoaded = true
        }
        let elapsed = ContinuousClock.now - start
        Self.log.info("library.index launch read \(elapsed, privacy: .public): \(index?.notebooks.count ?? -1) notebooks")
    }

    /// Wait before purging trash, so launch I/O stays free.
    static let purgeDelay = Duration.seconds(2)

    func start() async {
        if !isLoaded {
            let snapshot = await store.load { [weak self] snapshot in await self?.apply(snapshot) }
            apply(snapshot)
            isLoaded = true
        }
        #if DEBUG || PERF_FIXTURES
            if LaunchOptions.seedNotebooks > 0, notebooks.isEmpty {
                await seed(count: LaunchOptions.seedNotebooks)
            }
            if LaunchOptions.fixtureNotebookPages > 0 {
                await addFixture(pages: LaunchOptions.fixtureNotebookPages)
            }
        #endif
        let store = store
        // Purge runs on the store actor, never in the first 2 s after launch (#41).
        Task(priority: .background) {
            try? await Task.sleep(for: Self.purgeDelay)
            do {
                try await store.purgeTrash()
            } catch {
                Self.log.error("purge trash: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Notebooks

    func createNotebook(_ draft: NotebookDraft) async throws -> NotebookSummary {
        let entry = try await store.create(draft.makeNotebook(), in: draft.folderID)
        await refresh()
        return summary(entry)
    }

    func importPDF(_ draft: PDFImportDraft) async throws -> NotebookSummary {
        let entry = try await store.importPDF(draft.url, as: draft.makeNotebook(), in: draft.folderID)
        await refresh()
        return summary(entry)
    }

    func update(_ notebook: NotebookSummary) {
        guard let index = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        let old = notebooks[index]
        guard (old.title, old.cover, old.paper, old.theme) != (notebook.title, notebook.cover, notebook.paper, notebook.theme) else {
            notebooks[index] = notebook
            return
        }
        notebooks[index] = notebook
        let (id, title, cover, paper, theme) = (notebook.id, notebook.title, notebook.cover, notebook.paper, notebook.theme)
        perform("update") { store in
            try await store.updateNotebook(id) { n in
                n.title = title
                n.cover = cover
                n.paper = paper
                n.theme = theme
            }
        }
    }

    func documentURL(for id: NotebookID) async throws -> URL {
        if let path = packagePaths[id] {
            return locations.notebooksURL(path)
        }
        guard let entry = await store.snapshot().notebooks.first(where: { $0.id == id }) else {
            throw LibraryError.notFound(id)
        }
        return locations.packageURL(for: entry)
    }

    func documentDidSave(_ manifest: Manifest) {
        perform("did save") { try await $0.didSave(manifest) }
    }

    /// `cover.heic` was (re)written: the "Continue" card reloads it, with no index round trip.
    func coverDidChange(for id: NotebookID) {
        coverVersions[id] = Date()
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        var notebook = notebooks[index]
        applyCoverVersion(to: &notebook, packagePath: packagePaths[id])
        notebooks[index] = notebook
    }

    func rename(_ id: NotebookID, to title: String) {
        if let index = notebooks.firstIndex(where: { $0.id == id }) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            notebooks[index].title = trimmed.isEmpty ? "Untitled" : trimmed
        }
        perform("rename") { try await $0.rename(id, to: title) }
    }

    func move(_ id: NotebookID, to folder: FolderID?) {
        if let index = notebooks.firstIndex(where: { $0.id == id }) {
            notebooks[index].folderID = folder
        }
        perform("move") { try await $0.move(id, to: folder) }
    }

    func duplicate(_ id: NotebookID) {
        perform("duplicate") { try await $0.duplicate(id) }
    }

    func delete(_ id: NotebookID) {
        notebooks.removeAll { $0.id == id }
        perform("delete") { try await $0.delete(id) }
    }

    // MARK: Folders

    func createFolder(named name: String) {
        perform("create folder") { try await $0.createFolder(named: name) }
    }

    func renameFolder(_ id: FolderID, to name: String) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].name = name
        }
        perform("rename folder") { try await $0.renameFolder(id, to: name) }
    }

    func deleteFolder(_ id: FolderID) {
        folders.removeAll { $0.id == id }
        perform("delete folder") { try await $0.deleteFolder(id) }
    }

    // MARK: Private

    /// Runs `operation` on the store, then shows the store's state (which also undoes a failed optimistic edit).
    private func perform(_ name: String, _ operation: @escaping @Sendable (LibraryStore) async throws -> Void) {
        let store = store
        Task {
            do {
                try await operation(store)
            } catch {
                Self.log.error("\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            await refresh()
        }
    }

    private func refresh() async {
        await apply(store.snapshot())
    }

    /// Shows `snapshot` unless a newer one is already shown.
    private func apply(_ snapshot: LibrarySnapshot) {
        guard snapshot.generation >= generation else { return }
        generation = snapshot.generation
        notebooks = snapshot.notebooks.map(summary)
        packagePaths = Dictionary(snapshot.notebooks.map { ($0.id, $0.packagePath) }, uniquingKeysWith: { _, last in last })
        folders = snapshot.folders
    }

    private func summary(_ entry: LibraryEntry) -> NotebookSummary {
        var summary = NotebookSummary(entry, coverThumbnail: locations.coverThumbnailURL(for: entry))
        applyCoverVersion(to: &summary, packagePath: entry.packagePath)
        return summary
    }

    /// A cover written this launch: its version is the write time (if after the index's modified date),
    /// and the file is shown even before the index entry learns it exists.
    private func applyCoverVersion(to notebook: inout NotebookSummary, packagePath: String?) {
        guard let written = coverVersions[notebook.id] else { return }
        notebook.coverVersion = written > notebook.modifiedAt ? written : nil
        if notebook.coverThumbnail == nil, let packagePath {
            notebook.coverThumbnail = locations.notebooksURL("\(packagePath)/thumbs/cover.heic")
        }
    }
}

#if DEBUG || PERF_FIXTURES
    extension StoreLibrary {
        /// `-resetLibrary YES`: start from an empty container (UI tests).
        static func erase(_ locations: LibraryLocations = .standard) {
            try? FileManager.default.removeItem(at: locations.notebooksDirectory)
            try? FileManager.default.removeItem(at: locations.libraryDirectory)
        }

        /// `-seedNotebooks N`: N real notebooks shaped like the mock's (titles, covers, papers, folders,
        /// staggered modified dates) for screenshots and launch measurements.
        private func seed(count: Int) async {
            let sample = SampleLibrary()
            var folders: [String: FolderID] = [:]
            for folder in sample.folders {
                folders[folder.name] = try? await store.createFolder(named: folder.name).id
            }
            for i in 0 ..< count {
                let fixture = sample.notebooks[i % sample.notebooks.count]
                let round = i / sample.notebooks.count
                let date = fixture.modifiedAt.addingTimeInterval(-Double(round) * 40 * 86400)
                let notebook = Notebook(
                    title: round == 0 ? fixture.title : "\(fixture.title) \(round + 1)", cover: fixture.cover, paper: fixture.paper,
                    theme: fixture.theme, pages: (0 ..< fixture.pageCount).map { _ in PageID() }, createdAt: date, modifiedAt: date
                )
                let folder = sample.folder(id: fixture.folderID).flatMap { folders[$0.name] }
                _ = try? await store.create(notebook, in: folder)
            }
            await refresh()
        }

        /// `-fixtureNotebook N`: an N-page FixtureGen notebook (§12) for perf and scroll tests. Written once:
        /// its ID is deterministic, so later launches find the package and skip the (slow, Debug) generation.
        private func addFixture(pages: Int) async {
            let generator = FixtureGenerator(FixtureSpec(pages: pages))
            let id = generator.notebook.id
            guard !notebooks.contains(where: { $0.id == id }) else { return }
            let url = NotebookPackage.url(for: id, in: locations.notebooksDirectory)
            if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                let start = ContinuousClock.now
                do {
                    try FileManager.default.createDirectory(at: locations.notebooksDirectory, withIntermediateDirectories: true)
                    _ = try await Task.detached(priority: .userInitiated) { try generator.write(to: url) }.value
                } catch {
                    Self.log.error("fixture: \(error.localizedDescription, privacy: .public)")
                    return
                }
                Self.log.info("fixture \(pages) pages written in \(ContinuousClock.now - start, privacy: .public)")
            }
            await apply(store.rebuild())
        }
    }
#endif
