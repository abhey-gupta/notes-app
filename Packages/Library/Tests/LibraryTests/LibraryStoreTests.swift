import CoreGraphics
import Document
import Foundation
import InkModel
@testable import Library
import Testing

struct LibraryStoreTests {
    // MARK: CRUD

    @Test func createWritesPackageAndIndexEntry() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let entry = try await store.create(notebook("Thermodynamics", cover: .navy))

        #expect(entry.title == "Thermodynamics")
        #expect(entry.cover == .navy)
        #expect(entry.pageCount == 1, "a notebook with no pages gets one")
        #expect(entry.pageSize == Notebook.a4Portrait)
        #expect(entry.packagePath == "\(entry.id).nb")
        #expect(entry.coverThumbnailPath == nil)
        let package = try NotebookPackage.open(at: lib.locations.packageURL(for: entry))
        #expect(package.manifest.notebook.title == "Thermodynamics")
        #expect(await store.snapshot().notebooks == [entry])

        // Persisted: a fresh store and the synchronous launch read both see it.
        #expect(await lib.store().snapshot().notebooks == [entry])
        #expect(LibraryStore.readIndex(at: lib.locations)?.notebooks == [entry])
    }

    @Test func importPDFWritesOnePagePerPDFPageInTheFolder() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let folder = try await store.createFolder(named: "Physics")
        let pdf = lib.root.appending(path: "Slides.pdf")
        let context = try #require(CGContext(pdf as CFURL, mediaBox: nil, nil))
        for _ in 0 ..< 4 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()
        let entry = try await store.importPDF(pdf, as: notebook("Slides", pages: 0), in: folder.id)
        #expect(entry.title == "Slides" && entry.folderID == folder.id)
        #expect(entry.pageCount == 4)
        #expect(entry.pageSize == CGSize(width: 612, height: 792), "CoreGraphics' default media box")
        let package = try NotebookPackage.open(at: lib.locations.packageURL(for: entry))
        #expect(package.artwork().count == 4)
        #expect(lib.exists(pdf), "the source is copied, not moved")
        await #expect(throws: LibraryError.self) { try await store.importPDF(lib.root, as: notebook("x")) }
        #expect(await store.snapshot().notebooks.count == 1)
    }

    @Test func blankTitlesAreNumbered() async throws {
        let store = try TempLibrary().store()
        var titles: [String] = []
        for title in [" ", "", "Untitled 2", ""] {
            try await titles.append(store.create(notebook(title)).title)
        }
        #expect(titles == ["Untitled", "Untitled 2", "Untitled 2", "Untitled 3"])
    }

    @Test func notebooksAreMostRecentFirst() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.create(notebook("Old", modified: base))
        try await store.create(notebook("New", modified: base.addingTimeInterval(60)))
        try await store.create(notebook("Middle", modified: base.addingTimeInterval(30)))
        #expect(await store.snapshot().notebooks.map(\.title) == ["New", "Middle", "Old"])
    }

    @Test func renameUpdatesManifestAndIndex() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let entry = try await store.create(notebook("Draft"))
        let renamed = try await store.rename(entry.id, to: "  Final  ")

        #expect(renamed.title == "Final")
        #expect(renamed.modifiedAt >= entry.modifiedAt)
        #expect(renamed.rev > entry.rev)
        #expect(try NotebookPackage.readManifest(at: lib.locations.packageURL(for: entry)).notebook.title == "Final")
        #expect(await store.snapshot().notebook(entry.id)?.title == "Final")
        #expect(try await store.rename(entry.id, to: "   ").title == "Untitled")
    }

    @Test func updateNotebookPersistsAppearance() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let entry = try await store.create(notebook("Sketches"))
        try await store.updateNotebook(entry.id) { $0.theme = .night; $0.paper = .grid; $0.cover = .rose }
        let updated = try #require(await lib.store().snapshot().notebook(entry.id))
        #expect((updated.theme, updated.paper, updated.cover) == (.night, .grid, .rose))
    }

    @Test func moveToFolderAndFolderCRUD() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let entry = try await store.create(notebook("Lecture 1"))
        let physics = try await store.createFolder(named: "Physics")
        let work = try await store.createFolder(named: "  ")
        #expect(work.name == "New Folder")

        try await store.move(entry.id, to: physics.id)
        #expect(await store.snapshot().notebook(entry.id)?.folderID == physics.id)
        let unknown = FolderID()
        await #expect(throws: LibraryError.unknownFolder(unknown)) {
            try await store.move(entry.id, to: unknown)
        }
        await #expect(throws: LibraryError.self) {
            try await store.create(notebook("Nowhere"), in: FolderID())
        }

        try await store.renameFolder(physics.id, to: "Physics II")
        #expect(await store.snapshot().folders.map(\.name) == ["Physics II", "New Folder"])

        try await store.deleteFolder(physics.id)
        let snapshot = await lib.store().snapshot()
        #expect(snapshot.folders.map(\.name) == ["New Folder"])
        #expect(snapshot.notebook(entry.id)?.folderID == nil, "notebooks survive their folder, unfiled")
    }

    @Test func nestedFoldersPersistAndDeleteMovesContentsUp() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let school = try await store.createFolder(named: "School")
        let physics = try await store.createFolder(named: "Physics", in: school.id)
        let labs = try await store.createFolder(named: "Labs", in: physics.id)
        let entry = try await store.create(notebook("Optics"), in: physics.id)
        await #expect(throws: LibraryError.self) {
            try await store.createFolder(named: "Orphan", in: FolderID())
        }

        let reopened = await lib.store().snapshot().folders
        #expect(reopened.children(of: nil).map(\.name) == ["School"])
        #expect(reopened.children(of: school.id).map(\.name) == ["Physics"])
        #expect(reopened.path(to: labs.id).map(\.name) == ["School", "Physics", "Labs"])
        #expect(reopened.subtree(of: school.id) == [school.id, physics.id, labs.id])

        try await store.deleteFolder(physics.id)
        let snapshot = await lib.store().snapshot()
        #expect(snapshot.folders.children(of: school.id).map(\.name) == ["Labs"], "subfolders move up")
        #expect(snapshot.notebook(entry.id)?.folderID == school.id, "notebooks move up")
    }

    @Test func folderWithMissingParentIsTopLevel() {
        let folders = [LibraryFolder(name: "Lost", parentID: FolderID()), LibraryFolder(name: "Top")]
        #expect(folders.children(of: nil).map(\.name) == ["Lost", "Top"])
    }

    @Test func duplicateCopiesPackageUnderNewID() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let folder = try await store.createFolder(named: "Work")
        let source = try await store.create(notebook("Specs", pages: 3), in: folder.id)
        let page = try Page(
            id: NotebookPackage.open(at: lib.locations.packageURL(for: source)).manifest.notebook.pages[1],
            template: .grid(spacing: 20),
            rev: 2
        )
        var package = try NotebookPackage.open(at: lib.locations.packageURL(for: source))
        try package.savePage(page)

        let copy = try await store.duplicate(source.id)
        let second = try await store.duplicate(source.id)

        #expect(copy.id != source.id)
        #expect(copy.title == "Specs copy")
        #expect(second.title == "Specs copy 2")
        #expect(copy.folderID == folder.id)
        #expect(copy.pageCount == 3)
        let copied = try NotebookPackage.open(at: lib.locations.packageURL(for: copy))
        #expect(copied.manifest.notebook.id == copy.id)
        #expect(copied.manifest.pages[1].template == .grid(spacing: 20))
        #expect(try copied.loadPage(at: 1).rev == 2)
        #expect(await store.snapshot().notebooks.count == 3)
    }

    @Test func deleteMovesToTrashAndRestoreBringsBack() async throws {
        let lib = try TempLibrary()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = lib.store(now: { deletedAt })
        let entry = try await store.create(notebook("Scratch"))
        let packageURL = lib.locations.packageURL(for: entry)

        try await store.delete(entry.id)
        var snapshot = await store.snapshot()
        #expect(snapshot.notebooks.isEmpty)
        #expect(snapshot.trash.map(\.id) == [entry.id])
        #expect(snapshot.trash.first?.trashedAt == deletedAt)
        #expect(!lib.exists(packageURL))
        #expect(lib.exists(lib.locations.trashDirectory.appending(path: entry.packagePath)))
        await #expect(throws: LibraryError.notFound(entry.id)) { try await store.delete(entry.id) }

        try await store.restore(entry.id)
        snapshot = await lib.store().snapshot()
        #expect(snapshot.notebooks.map(\.id) == [entry.id])
        #expect(snapshot.trash.isEmpty)
        #expect(lib.exists(packageURL))
    }

    @Test func trashPurgesAfterThirtyDays() async throws {
        let lib = try TempLibrary()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = lib.store(now: { deletedAt })
        let old = try await store.create(notebook("Old"))
        let kept = try await store.create(notebook("Kept"))
        try await store.delete(old.id)
        try await store.delete(kept.id)

        let day: TimeInterval = 86400
        #expect(try await store.purgeTrash(now: deletedAt.addingTimeInterval(29 * day)) == 0)
        #expect(await store.snapshot().trash.count == 2)

        // Make "Kept" younger by restoring and re-deleting it later.
        try await store.restore(kept.id)
        let laterStore = LibraryStore(locations: lib.locations, now: { deletedAt.addingTimeInterval(10 * day) })
        try await laterStore.delete(kept.id)

        #expect(try await laterStore.purgeTrash(now: deletedAt.addingTimeInterval(31 * day)) == 1)
        let snapshot = await lib.store().snapshot()
        #expect(snapshot.trash.map(\.id) == [kept.id])
        #expect(!lib.exists(lib.locations.trashDirectory.appending(path: old.packagePath)))
        #expect(lib.exists(lib.locations.trashDirectory.appending(path: kept.packagePath)))
    }

    @Test func missingNotebookThrows() async throws {
        let store = try TempLibrary().store()
        let id = NotebookID()
        await #expect(throws: LibraryError.notFound(id)) { try await store.rename(id, to: "x") }
        await #expect(throws: LibraryError.notFound(id)) { try await store.duplicate(id) }
        await #expect(throws: LibraryError.notFound(id)) { try await store.restore(id) }
    }

    // MARK: Checkpoints

    @Test func didSaveUpdatesEntryAndIgnoresStaleManifests() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let entry = try await store.create(notebook("Journal"))
        var package = try NotebookPackage.open(at: lib.locations.packageURL(for: entry))
        let stale = package.manifest
        try package.insertPage()
        try package.insertPage()
        try package.updateNotebook { $0.title = "Journal 2026" }
        try Data([0]).write(to: package.coverThumbnailURL)

        try await store.didSave(package.manifest)
        var updated = try #require(await store.snapshot().notebook(entry.id))
        #expect(updated.pageCount == 3)
        #expect(updated.title == "Journal 2026")
        #expect(updated.coverThumbnailPath == "\(entry.packagePath)/thumbs/cover.heic")
        #expect(lib.locations.coverThumbnailURL(for: updated) == package.coverThumbnailURL)

        try await store.didSave(stale)
        updated = try #require(await store.snapshot().notebook(entry.id))
        #expect(updated.pageCount == 3, "older rev ignored")

        try package.insertPage()
        try await store.refresh(entry.id)
        #expect(await store.snapshot().notebook(entry.id)?.pageCount == 4)
    }

    @Test func concurrentMutationsAllLand() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 20 {
                group.addTask { try await store.create(notebook("N\(i)")) }
            }
            try await group.waitForAll()
        }
        #expect(await lib.store().snapshot().notebooks.count == 20)
    }
}
