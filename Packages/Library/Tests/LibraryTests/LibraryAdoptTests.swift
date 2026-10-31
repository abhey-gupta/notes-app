import Document
import Foundation
import InkModel
@testable import Library
import Testing

/// ``LibraryStore/adoptPackage(at:in:folders:)``: Restore from a backup (#174).
struct LibraryAdoptTests {
    /// A package written outside the library, as a restore stages it.
    private func stage(_ notebook: Notebook, in lib: TempLibrary) throws -> URL {
        let url = lib.locations.notebooksDirectory.appending(path: ".restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try NotebookPackage.create(at: url, notebook: notebook)
        return url
    }

    @Test func adoptsPackageAndRecreatesFoldersWithTheirIDs() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let university = LibraryFolder(name: "University")
        let physics = LibraryFolder(name: "Physics", parentID: university.id)
        let other = LibraryFolder(name: "Unrelated")
        let staged = try stage(notebook("Thermodynamics", pages: 3), in: lib)

        let entry = try await store.adoptPackage(at: staged, in: physics.id, folders: [other, university, physics])
        #expect(entry.title == "Thermodynamics" && entry.pageCount == 3)
        #expect(entry.folderID == physics.id)
        #expect(entry.packagePath == "\(entry.id).nb")
        #expect(!lib.exists(staged))
        #expect(lib.exists(lib.locations.packageURL(for: entry)))
        let snapshot = await store.snapshot()
        #expect(snapshot.folders == [university, physics], "only the folders on the way, parents first")
        #expect(snapshot.notebooks == [entry])
        #expect(await lib.store().snapshot().notebooks == [entry], "persisted")
    }

    @Test func keepsLocalFolderAndUnknownFolderFilesNowhere() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let local = try await store.createFolder(named: "Maths")
        let renamed = LibraryFolder(id: local.id, name: "Old name")
        let a = try await store.adoptPackage(at: stage(notebook("A"), in: lib), in: local.id, folders: [renamed])
        #expect(a.folderID == local.id)
        #expect(await store.snapshot().folders == [local], "local name wins")
        let b = try await store.adoptPackage(at: stage(notebook("B"), in: lib), in: FolderID(), folders: [])
        #expect(b.folderID == nil)
    }

    @Test func neverReplacesANotebookInTheLibraryOrTrash() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let live = try await store.create(notebook("Live"))
        let trashed = try await store.create(notebook("Trashed"))
        try await store.delete(trashed.id)
        for entry in [live, trashed] {
            let copy = Notebook(id: entry.id, title: "Backup copy")
            let staged = try stage(copy, in: lib)
            await #expect(throws: LibraryError.alreadyInLibrary(entry.id)) {
                try await store.adoptPackage(at: staged, in: nil)
            }
            #expect(lib.exists(staged), "left where it was")
        }
        let manifest = try NotebookPackage.readManifest(at: lib.locations.packageURL(for: live))
        #expect(manifest.notebook.title == "Live")
    }

    /// Another device purged it (#225): gone from the library or its trash, files and all.
    @Test func purgeDeletesNotebookOrTrashedNotebook() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let live = try await store.create(notebook("Live"))
        let trashed = try await store.create(notebook("Trashed"))
        try await store.delete(trashed.id)
        try await store.purge(live.id)
        try await store.purge(trashed.id)
        let snapshot = await lib.store().snapshot()
        #expect(snapshot.notebooks.isEmpty && snapshot.trash.isEmpty)
        #expect(!lib.exists(lib.locations.packageURL(for: live)))
        #expect(!lib.exists(lib.locations.trashDirectory.appending(path: trashed.packagePath)))
        await #expect(throws: LibraryError.notFound(live.id)) { try await store.purge(live.id) }
    }
}
