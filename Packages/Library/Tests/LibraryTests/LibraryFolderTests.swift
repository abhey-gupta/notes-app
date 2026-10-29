import CoreGraphics
import Document
import Foundation
import InkModel
@testable import Library
import Testing

/// Nested folders (#117): any depth, cascading delete.
struct LibraryFolderTests {
    @Test func nestedFoldersToAnyDepth() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let uni = try await store.createFolder(named: "University")
        let term = try await store.createFolder(named: "Semester 3", in: uni.id)
        let physics = try await store.createFolder(named: "Physics II", in: term.id)
        let work = try await store.createFolder(named: "Work")
        let unknown = FolderID()
        await #expect(throws: LibraryError.unknownFolder(unknown)) {
            try await store.createFolder(named: "Orphan", in: unknown)
        }

        let folders = await lib.store().snapshot().folders
        #expect(physics.parentID == term.id)
        #expect(folders.children(of: nil).map(\.name) == ["University", "Work"])
        #expect(folders.children(of: uni.id).map(\.name) == ["Semester 3"])
        #expect(folders.subtree(of: uni.id) == [uni.id, term.id, physics.id])
        #expect(folders.subtree(of: work.id) == [work.id])
        #expect(folders.path(to: physics.id).map(\.name) == ["University", "Semester 3", "Physics II"])
        #expect(folders.path(to: FolderID()).isEmpty)
    }

    @Test func deleteFolderTrashesEverythingInside() async throws {
        let lib = try TempLibrary()
        let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = lib.store(now: { deletedAt })
        let uni = try await store.createFolder(named: "University")
        let term = try await store.createFolder(named: "Semester 3", in: uni.id)
        let work = try await store.createFolder(named: "Work")
        let top = try await store.create(notebook("Admin"), in: uni.id)
        let nested = try await store.create(notebook("Linear Algebra"), in: term.id)
        let kept = try await store.create(notebook("Specs"), in: work.id)
        let loose = try await store.create(notebook("Scratch"))

        try await store.deleteFolder(uni.id)
        let snapshot = await lib.store().snapshot()
        #expect(snapshot.folders.map(\.id) == [work.id])
        #expect(Set(snapshot.notebooks.map(\.id)) == [kept.id, loose.id])
        #expect(Set(snapshot.trash.map(\.id)) == [top.id, nested.id])
        #expect(snapshot.trash.allSatisfy { $0.trashedAt == deletedAt })
        for entry in [top, nested] {
            #expect(!lib.exists(lib.locations.packageURL(for: entry)))
            #expect(lib.exists(lib.locations.trashDirectory.appending(path: entry.packagePath)))
        }

        // Restored notebooks come back unfiled: their folder is gone.
        try await store.restore(nested.id)
        #expect(await store.snapshot().notebook(nested.id)?.folderID == nil)
    }

    @Test func folderParentRoundTripsThroughTheIndex() throws {
        let parent = LibraryFolder(name: "University")
        let child = LibraryFolder(name: "Semester 3", parentID: parent.id)
        let index = LibraryIndex(folders: [parent, child])
        #expect(try LibraryIndex.decode(index.encoded()).folders == [parent, child])
    }
}
