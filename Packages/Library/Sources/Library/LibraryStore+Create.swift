import Document
import Foundation
import InkModel

/// New notebooks: blank (``create(_:in:)``) or from a PDF (``importPDF(_:as:in:)``, #119).
public extension LibraryStore {
    /// Creates the notebook's package (one blank page if it has none) and its index entry, as one step:
    /// if the index can't be written, the package is removed again. A blank title becomes "Untitled",
    /// then "Untitled 2", "Untitled 3"…
    @discardableResult
    func create(_ notebook: Notebook, in folder: FolderID? = nil) async throws(LibraryError) -> LibraryEntry {
        try await create(notebook, in: folder) { url, notebook throws(DocumentError) in
            try NotebookPackage.create(at: url, notebook: notebook)
        }
    }

    /// Package first, then the index entry (``create(_:in:)``, ``importPDF(_:as:in:)``).
    internal func create(
        _ notebook: Notebook,
        in folder: FolderID?,
        write: (URL, Notebook) throws(DocumentError) -> NotebookPackage
    ) async throws(LibraryError) -> LibraryEntry {
        var next = await loadedIndex()
        try Self.check(folder, in: next)
        var notebook = notebook
        if notebook.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            notebook.title = Self.numbered("Untitled", taken: Set(next.notebooks.map(\.title)))
        }
        let url = NotebookPackage.url(for: notebook.id, in: locations.notebooksDirectory)
        let package: NotebookPackage
        do {
            package = try write(url, notebook)
        } catch {
            throw .document(error)
        }
        let entry = LibraryEntry(manifest: package.manifest, packagePath: url.lastPathComponent, folderID: folder)
        next.notebooks.append(entry)
        do {
            try commit(next)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return entry
    }

    /// Creates a notebook from a PDF (#119): one page per PDF page, drawn on a copy of the file kept in
    /// the package (``NotebookPackage/create(at:notebook:pdf:)``), then its index entry. `pdf` is only read.
    func importPDF(_ pdf: URL, as notebook: Notebook, in folder: FolderID? = nil) async throws(LibraryError) -> LibraryEntry {
        try await create(notebook, in: folder) { url, notebook throws(DocumentError) in
            try NotebookPackage.create(at: url, notebook: notebook, pdf: pdf)
        }
    }
}
