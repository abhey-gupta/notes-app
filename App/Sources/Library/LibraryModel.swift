import Foundation
import InkModel
import Observation

/// What the Library screen needs from storage. `SampleLibrary` (in-memory fixtures) backs it until
/// `LibraryStore` (#34) lands; screens only see this protocol.
@MainActor
protocol LibraryModel: AnyObject, Observable {
    /// All notebooks, most recently modified first.
    var notebooks: [NotebookSummary] { get }
    /// One level of folders, display order.
    var folders: [LibraryFolder] { get }

    /// Creates a notebook (one blank page) and returns it. The caller opens it immediately (§8).
    @discardableResult
    func createNotebook(_ draft: NotebookDraft) -> NotebookSummary
    /// Persists metadata edits (title, paper theme, …).
    func update(_ notebook: NotebookSummary)
}

extension LibraryModel {
    /// "Continue" row: last 6 by modified.
    var recents: [NotebookSummary] {
        Array(notebooks.prefix(6))
    }

    func notebook(id: NotebookID) -> NotebookSummary? {
        notebooks.first { $0.id == id }
    }

    func folder(id: LibraryFolder.ID?) -> LibraryFolder? {
        id.flatMap { id in folders.first { $0.id == id } }
    }

    /// Title search: case/diacritic-insensitive, in memory (§8).
    func notebooks(in folder: LibraryFolder.ID?, matching query: String) -> [NotebookSummary] {
        let query = query.trimmingCharacters(in: .whitespaces)
        return notebooks.filter { notebook in
            (folder == nil || notebook.folderID == folder) && (query.isEmpty || notebook.title.localizedStandardContains(query))
        }
    }
}

/// Index entry: everything the library and the editor's first frame need, nothing from the package.
struct NotebookSummary: Identifiable, Hashable {
    let id: NotebookID
    var title: String
    var folderID: LibraryFolder.ID?
    var cover: CoverColor
    var paper: PaperStyle
    var theme: PaperTheme
    var pageCount: Int
    var modifiedAt: Date
    /// Placeholder ink on fixture pages until real documents load (#21/#34). Nil = blank notebook.
    var sampleInk: SampleInk.Kind?
}

struct LibraryFolder: Identifiable, Hashable {
    let id: UUID
    var name: String
}

/// New-notebook sheet output (§8).
struct NotebookDraft {
    var title = ""
    var cover: CoverColor = .navy
    var paper: PaperStyle = .dotted
    var theme: PaperTheme = .cream
    var folderID: LibraryFolder.ID?

    var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}
