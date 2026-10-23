import CoreGraphics
import Document
import Foundation
import InkModel
import Library
import Observation

/// What the Library screen needs from storage. `StoreLibrary` (the on-disk `LibraryStore`, #34) backs the
/// app; `SampleLibrary` (in-memory fixtures) backs previews and `-sampleLibrary YES`. Screens only see this.
///
/// Mutations other than create are fire-and-forget: they apply to `notebooks` immediately and persist in
/// the background.
@MainActor
protocol LibraryModel: AnyObject, Observable {
    /// All notebooks, most recently modified first.
    var notebooks: [NotebookSummary] { get }
    /// One level of folders, display order.
    var folders: [LibraryFolder] { get }
    /// `false` only while the index is still being read or rebuilt off the main thread; the empty state
    /// waits for it so a slow load never flashes "No notebooks yet".
    var isLoaded: Bool { get }

    /// Post-first-frame work: finish loading if the launch read couldn't, purge old trash.
    func start() async
    /// Creates a notebook (package + index entry, one blank page) and returns it. The caller opens it (§8).
    func createNotebook(_ draft: NotebookDraft) async throws -> NotebookSummary
    /// Persists metadata edits (title, cover, paper, theme) made outside the editor.
    func update(_ notebook: NotebookSummary)
    /// The notebook's package, for the editor's `DocumentStore` (§8). While the editor is open its store is
    /// the package's only writer: metadata edits go through the store and come back via `documentDidSave`.
    func documentURL(for id: NotebookID) async throws -> URL
    /// The editor's store wrote the manifest (checkpoint, page added, paper changed): refresh the entry
    /// (modified date, page count, cover thumbnail…).
    func documentDidSave(_ manifest: Manifest)
    func rename(_ id: NotebookID, to title: String)
    func move(_ id: NotebookID, to folder: FolderID?)
    func duplicate(_ id: NotebookID)
    /// Moves to the trash (purged after 30 days).
    func delete(_ id: NotebookID)
    func createFolder(named name: String)
    func renameFolder(_ id: FolderID, to name: String)
    /// Removes the folder; its notebooks stay, unfiled.
    func deleteFolder(_ id: FolderID)
}

extension LibraryModel {
    /// "Continue" row: last 6 by modified (`notebooks` is already in that order).
    var recents: [NotebookSummary] {
        Array(notebooks.prefix(6))
    }

    func notebook(id: NotebookID) -> NotebookSummary? {
        notebooks.first { $0.id == id }
    }

    func folder(id: FolderID?) -> LibraryFolder? {
        id.flatMap { id in folders.first { $0.id == id } }
    }

    /// Title search: case/diacritic-insensitive, in memory (§8).
    func notebooks(in folder: FolderID?, matching query: String) -> [NotebookSummary] {
        notebooks.filtered(folder: folder, matching: query)
    }
}

/// Index entry as the screens see it: everything the library and the editor's first frame need.
struct NotebookSummary: Identifiable, Hashable, LibraryItem {
    let id: NotebookID
    var title: String
    var folderID: FolderID?
    var cover: CoverColor
    var paper: PaperStyle
    var theme: PaperTheme
    var pageCount: Int
    var createdAt: Date
    var modifiedAt: Date
    var pageSize: CGSize = Notebook.a4Portrait
    /// `thumbs/cover.heic`, when the notebook has one (§5.5). Recents show it over the paper preview.
    var coverThumbnail: URL?
    /// Placeholder ink on fixture pages (`SampleLibrary` only). Nil = blank notebook.
    var sampleInk: SampleInk.Kind?
}

extension NotebookSummary {
    init(_ entry: LibraryEntry, coverThumbnail: URL?) {
        self.init(
            id: entry.id, title: entry.title, folderID: entry.folderID, cover: entry.cover, paper: entry.paper,
            theme: entry.theme, pageCount: entry.pageCount, createdAt: entry.createdAt, modifiedAt: entry.modifiedAt,
            pageSize: entry.pageSize, coverThumbnail: coverThumbnail
        )
    }
}

/// New-notebook sheet output (§8).
struct NotebookDraft {
    var title = ""
    var cover: CoverColor = .navy
    var paper: PaperStyle = .dotted
    var theme: PaperTheme = .cream
    var folderID: FolderID?

    var resolvedTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    /// The notebook to write: A4 portrait, created now.
    func makeNotebook(now: Date = Date()) -> Notebook {
        Notebook(title: resolvedTitle, cover: cover, paper: paper, theme: theme, createdAt: now)
    }
}
