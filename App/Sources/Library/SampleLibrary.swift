import Foundation
import InkModel
import Observation

/// In-memory library seeded with the mock's notebooks. Replaced by `LibraryStore` (#34).
/// Init is a handful of struct copies: safe on the launch path.
@MainActor
@Observable
final class SampleLibrary: LibraryModel {
    private(set) var notebooks: [NotebookSummary]
    private(set) var folders: [LibraryFolder]

    init(now: Date = Date(), empty: Bool = false) {
        let physics = LibraryFolder(id: UUID(), name: "Physics II")
        let semester = LibraryFolder(id: UUID(), name: "Semester 3")
        let work = LibraryFolder(id: UUID(), name: "Work")
        let personal = LibraryFolder(id: UUID(), name: "Personal")
        folders = [physics, semester, work, personal]
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
                theme: .white, pageCount: 11, modifiedAt: ago(120), sampleInk: .lecture
            ),
            .init(
                id: NotebookID(), title: "Product Specs", folderID: work.id, cover: .navy, paper: .grid,
                theme: .white, pageCount: 4, modifiedAt: ago(day + 2 * hour), sampleInk: .wireframe
            ),
            .init(
                id: NotebookID(), title: "Studio Journal", folderID: personal.id, cover: .terracotta, paper: .lined,
                theme: .cream, pageCount: 31, modifiedAt: ago(3 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Launch Plan", folderID: work.id, cover: .sky, paper: .dotted,
                theme: .night, pageCount: 3, modifiedAt: ago(4 * day), sampleInk: .mindMap
            ),
            .init(
                id: NotebookID(), title: "Sketchbook", folderID: personal.id, cover: .sand, paper: .blank,
                theme: .cream, pageCount: 48, modifiedAt: ago(9 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Linear Algebra", folderID: semester.id, cover: .plum, paper: .grid,
                theme: .white, pageCount: 9, modifiedAt: ago(12 * day), sampleInk: .lecture
            ),
            .init(
                id: NotebookID(), title: "Meeting Notes", folderID: work.id, cover: .graphite, paper: .lined,
                theme: .white, pageCount: 22, modifiedAt: ago(20 * day), sampleInk: .journal
            ),
            .init(
                id: NotebookID(), title: "Field Recordings", folderID: personal.id, cover: .rose, paper: .dotted,
                theme: .cream, pageCount: 6, modifiedAt: ago(34 * day), sampleInk: .journal
            ),
        ]
    }

    @discardableResult
    func createNotebook(_ draft: NotebookDraft) -> NotebookSummary {
        let notebook = NotebookSummary(
            id: NotebookID(),
            title: draft.resolvedTitle,
            folderID: draft.folderID,
            cover: draft.cover,
            paper: draft.paper,
            theme: draft.theme,
            pageCount: 1,
            modifiedAt: Date(),
            sampleInk: nil
        )
        notebooks.insert(notebook, at: 0)
        return notebook
    }

    func update(_ notebook: NotebookSummary) {
        guard let index = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[index] = notebook
    }
}
