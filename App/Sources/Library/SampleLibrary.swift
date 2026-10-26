import Document
import Foundation
import InkModel
import Library
import Observation
#if DEBUG
    import FixtureGen
#endif

/// In-memory library seeded with the mock's notebooks: previews, screenshots, `-sampleLibrary YES`.
/// Nothing persists beyond the process: opening a notebook writes a scratch package to the temporary
/// directory (DEBUG: FixtureGen handwriting; Release: blank pages). Init is a handful of struct copies:
/// safe on the launch path.
@MainActor
@Observable
final class SampleLibrary: LibraryModel {
    private(set) var notebooks: [NotebookSummary]
    private(set) var folders: [LibraryFolder]
    @ObservationIgnored private var packages: [NotebookID: URL] = [:]
    @ObservationIgnored private let scratch = FileManager.default.temporaryDirectory
        .appending(path: "SampleLibrary-\(UUID().uuidString)", directoryHint: .isDirectory)
    let isLoaded = true

    init(now: Date = Date(), empty: Bool = false) {
        let semester = LibraryFolder(name: "Semester 3")
        let physics = LibraryFolder(name: "Physics II", parentID: semester.id)
        let work = LibraryFolder(name: "Work")
        let personal = LibraryFolder(name: "Personal")
        folders = [semester, physics, work, personal]
        guard !empty else {
            notebooks = []
            return
        }

        func ago(_ seconds: TimeInterval) -> Date {
            now.addingTimeInterval(-seconds)
        }
        let hour: TimeInterval = 3600, day = 24 * hour
        notebooks = [
            .init(
                id: NotebookID(), title: "Thermodynamics", folderID: physics.id, cover: .sage, paper: .dotted,
                theme: .white, pageCount: 11, createdAt: ago(120), modifiedAt: ago(120), sampleInk: .lecture
            ),
            .init(
                id: NotebookID(), title: "Product Specs", folderID: work.id, cover: .navy, paper: .grid,
                theme: .white, pageCount: 4, createdAt: ago(day + 2 * hour), modifiedAt: ago(day + 2 * hour), sampleInk: .wireframe
            ),
            .init(
                id: NotebookID(), title: "Studio Journal", folderID: personal.id, cover: .terracotta, paper: .lined,
                theme: .cream, pageCount: 31, createdAt: ago(3 * day), modifiedAt: ago(3 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Launch Plan", folderID: work.id, cover: .sky, paper: .dotted,
                theme: .night, pageCount: 3, createdAt: ago(4 * day), modifiedAt: ago(4 * day), sampleInk: .mindMap
            ),
            .init(
                id: NotebookID(), title: "Sketchbook", folderID: personal.id, cover: .sand, paper: .blank,
                theme: .cream, pageCount: 48, createdAt: ago(9 * day), modifiedAt: ago(9 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Linear Algebra", folderID: semester.id, cover: .plum, paper: .grid,
                theme: .white, pageCount: 9, createdAt: ago(12 * day), modifiedAt: ago(12 * day), sampleInk: .lecture
            ),
            .init(
                id: NotebookID(), title: "Meeting Notes", folderID: work.id, cover: .graphite, paper: .lined,
                theme: .white, pageCount: 22, createdAt: ago(20 * day), modifiedAt: ago(20 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Field Recordings", folderID: personal.id, cover: .rose, paper: .dotted,
                theme: .cream, pageCount: 6, createdAt: ago(34 * day), modifiedAt: ago(34 * day), sampleInk: .journal
            ),
        ]
    }

    func start() async {}

    func createNotebook(_ draft: NotebookDraft) async throws -> NotebookSummary {
        let now = Date()
        let notebook = NotebookSummary(
            id: NotebookID(), title: draft.resolvedTitle, folderID: draft.folderID, cover: draft.cover, paper: draft.paper,
            theme: draft.theme, pageCount: 1, createdAt: now, modifiedAt: now
        )
        notebooks.insert(notebook, at: 0)
        return notebook
    }

    func update(_ notebook: NotebookSummary) {
        guard let index = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[index] = notebook
    }

    func documentURL(for id: NotebookID) async throws -> URL {
        if let url = packages[id] {
            return url
        }
        guard let summary = notebook(id: id) else { throw LibraryError.notFound(id) }
        let url = scratch.appending(path: "\(id).\(NotebookPackage.pathExtension)", directoryHint: .isDirectory)
        let directory = scratch
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.writePackage(for: summary, at: url)
        }.value
        packages[id] = url
        return url
    }

    func documentDidSave(_ manifest: Manifest) {
        guard let index = notebooks.firstIndex(where: { $0.id == manifest.notebook.id }) else { return }
        notebooks[index].pageCount = manifest.pages.count
        notebooks[index].theme = manifest.notebook.theme
        notebooks[index].paper = manifest.notebook.paper
        notebooks[index].modifiedAt = manifest.notebook.modifiedAt
    }

    /// The mock notebook as a package: same ID, pages, paper and theme; DEBUG fills pages with FixtureGen ink.
    private nonisolated static func writePackage(for summary: NotebookSummary, at url: URL) throws {
        let pageCount = max(summary.pageCount, 1)
        #if DEBUG
            if summary.sampleInk != nil {
                let generator = FixtureGenerator(FixtureSpec(
                    pages: pageCount, seed: summary.title.unicodeScalars.reduce(1) { $0 &* 31 &+ UInt64($1.value) }, strokesPerPage: 140,
                    theme: summary.theme, paper: summary.paper
                ))
                let generated = generator.notebook
                let notebook = Notebook(
                    id: summary.id, title: summary.title, cover: summary.cover, paper: summary.paper, theme: summary.theme,
                    pages: generated.pages, createdAt: summary.createdAt, modifiedAt: summary.modifiedAt
                )
                _ = try NotebookPackage.create(at: url, notebook: notebook, pages: generator.pages)
                return
            }
        #endif
        let notebook = Notebook(
            id: summary.id, title: summary.title, cover: summary.cover, paper: summary.paper, theme: summary.theme,
            pages: (0 ..< pageCount).map { _ in PageID() }, createdAt: summary.createdAt, modifiedAt: summary.modifiedAt
        )
        _ = try NotebookPackage.create(at: url, notebook: notebook)
    }

    func rename(_ id: NotebookID, to title: String) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        notebooks[index].title = trimmed.isEmpty ? "Untitled" : trimmed
    }

    func move(_ id: NotebookID, to folder: FolderID?) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[index].folderID = folder
    }

    func duplicate(_ id: NotebookID) {
        guard var copy = notebook(id: id) else { return }
        copy = NotebookSummary(
            id: NotebookID(), title: "\(copy.title) copy", folderID: copy.folderID, cover: copy.cover, paper: copy.paper,
            theme: copy.theme, pageCount: copy.pageCount, createdAt: Date(), modifiedAt: Date(), sampleInk: copy.sampleInk
        )
        notebooks.insert(copy, at: 0)
    }

    func delete(_ id: NotebookID) {
        notebooks.removeAll { $0.id == id }
    }

    func createFolder(named name: String, in parent: FolderID?) {
        folders.append(LibraryFolder(name: name, parentID: parent))
    }

    func renameFolder(_ id: FolderID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
    }

    func deleteFolder(_ id: FolderID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        let parent = folders.remove(at: index).parentID
        for index in folders.indices where folders[index].parentID == id {
            folders[index].parentID = parent
        }
        for index in notebooks.indices where notebooks[index].folderID == id {
            notebooks[index].folderID = parent
        }
    }
}
