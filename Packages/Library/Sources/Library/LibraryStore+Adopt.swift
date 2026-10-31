import Document
import Foundation
import InkModel

/// Packages written elsewhere: Restore from a backup (#174).
public extension LibraryStore {
    /// Takes in the package at `url` (staged by the caller in the Notebooks directory, so the move is a
    /// rename): moves it to `Notebooks/<id>.nb`, files it in `folder` and adds its index entry. Folders on
    /// the way to `folder` that the library lacks are recreated from `folders` with their IDs, names and
    /// parents; a folder the library has keeps its local name. An unknown `folder` files it nowhere.
    ///
    /// Never replaces a notebook: one with the same ID in the library or its trash throws
    /// ``LibraryError/alreadyInLibrary(_:)`` and leaves `url` where it is. If the index can't be written
    /// the package goes back to `url`.
    @discardableResult
    func adoptPackage(at url: URL, in folder: FolderID?, folders: [LibraryFolder] = []) async throws(LibraryError) -> LibraryEntry {
        var next = await loadedIndex()
        let manifest: Manifest
        do {
            manifest = try NotebookPackage.readManifest(at: url)
        } catch {
            throw .document(error)
        }
        let id = manifest.notebook.id
        guard !next.notebooks.contains(where: { $0.id == id }), !next.trash.contains(where: { $0.id == id }) else {
            throw .alreadyInLibrary(id)
        }
        var filed: FolderID?
        if let folder, next.folders.contains(where: { $0.id == folder }) {
            filed = folder
        } else if let folder {
            for missing in folders.path(to: folder) where !next.folders.contains(where: { $0.id == missing.id }) {
                next.folders.append(missing)
            }
            filed = next.folders.contains { $0.id == folder } ? folder : nil
        }
        let destination = NotebookPackage.url(for: id, in: locations.notebooksDirectory)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: locations.notebooksDirectory, withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: destination)
        } catch {
            throw .io(destination, reason: "\(error)")
        }
        let packagePath = destination.lastPathComponent
        let entry = LibraryEntry(
            manifest: manifest, packagePath: packagePath, folderID: filed,
            coverThumbnailPath: coverThumbnailPath(forPackage: packagePath)
        )
        next.notebooks.append(entry)
        do {
            try commit(next)
        } catch {
            try? fm.moveItem(at: destination, to: url)
            throw error
        }
        return entry
    }
}
