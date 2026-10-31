import Document
import Foundation
import InkModel
import Library

/// Reads the library side of a run: one `stat` per notebook (manifest, cover), and a full read only of the
/// notebooks the planner asks for.
enum LocalScan {
    /// Every notebook in `snapshot` and its trash.
    static func notebooks(in snapshot: LibrarySnapshot, locations: LibraryLocations) -> [LocalNotebook] {
        let live = snapshot.notebooks.map { ($0, BackupLocation.notebooks, locations.packageURL(for: $0)) }
        let trashed = snapshot.trash.map {
            ($0.entry, BackupLocation.trash, locations.trashDirectory.appending(path: $0.entry.packagePath, directoryHint: .isDirectory))
        }
        return (live + trashed).map { notebook($0, at: $1, url: $2) }
    }

    /// One package, as a run first sees it (manifest and cover stamps, no contents).
    static func notebook(_ entry: LibraryEntry, at location: BackupLocation, url: URL) -> LocalNotebook {
        let thumbs = NotebookPackage.thumbnailsDirectory(in: url)
        return LocalNotebook(
            entry: entry, location: location, packageURL: url,
            manifestModified: stamp(url.appending(path: "manifest.json"))?.modified,
            cover: stamp(thumbs.appending(path: "cover.heic"))
        )
    }

    /// Reads the manifest and lists the files a backup holds. Unreadable: left uninspected (and so unplanned).
    static func inspect(_ notebook: inout LocalNotebook) {
        guard let manifest = try? NotebookPackage.readManifest(at: notebook.packageURL) else {
            notebook.manifestModified = nil
            return
        }
        var files: [String: Int64] = [:]
        files["manifest.json"] = stamp(notebook.packageURL.appending(path: "manifest.json"))?.size ?? 0
        for directory in ["pages", "images", "backgrounds"] {
            let url = notebook.packageURL.appending(path: directory, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []
            for name in names where !name.hasPrefix(".") && (directory != "pages" || name.hasSuffix(".strokes")) {
                if let stamp = stamp(url.appending(path: name)) {
                    files["\(directory)/\(name)"] = stamp.size
                }
            }
        }
        notebook.contents = LocalNotebook.Contents(manifest: manifest, files: files)
    }

    /// Modification date and size of a regular file; `nil` if missing.
    static func stamp(_ url: URL) -> FileStamp? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let modified = values.contentModificationDate else { return nil }
        return FileStamp(modified: modified, size: Int64(values.fileSize ?? 0))
    }
}
