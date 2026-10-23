import Document
import Foundation
import InkModel
@testable import Library
import Testing

/// Missing, corrupt and newer indexes; rebuilds from packages.
struct LibraryRecoveryTests {
    @Test func rebuildsFromPackagesWhenIndexMissing() async throws {
        let lib = try TempLibrary()
        let notebooks = lib.locations.notebooksDirectory
        let count = 70
        for i in 0 ..< count {
            let n = notebook("Notebook \(i)", pages: i % 4 + 1, modified: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
            _ = try NotebookPackage.create(at: NotebookPackage.url(for: n.id, in: notebooks), notebook: n)
        }
        // Junk that must be skipped.
        try FileManager.default.createDirectory(at: notebooks.appending(path: "broken.nb"), withIntermediateDirectories: true)
        try Data("{".utf8).write(to: notebooks.appending(path: "broken.nb/manifest.json"))

        #expect(LibraryStore.readIndex(at: lib.locations) == nil)
        let partials = Partials()
        let snapshot = await lib.store().load { await partials.append($0) }

        #expect(snapshot.isComplete)
        #expect(snapshot.notebooks.count == count)
        #expect(snapshot.notebooks.first?.title == "Notebook 69")
        #expect(snapshot.notebooks.last?.pageCount == 1)
        let seen = await partials.counts
        #expect(seen == [32, 64], "progressive snapshots every \(LibraryStore.rebuildBatch) manifests")
        #expect(LibraryStore.readIndex(at: lib.locations)?.notebooks == snapshot.notebooks, "rebuilt index written")
    }

    @Test func corruptIndexIsSetAsideAndRebuilt() async throws {
        let lib = try TempLibrary()
        let entry = try await lib.store().create(notebook("Survivor"))
        let garbage = Data("{\"formatVersion\":1,\"notebooks\":[{\"id\":42}]".utf8)
        try garbage.write(to: lib.locations.indexURL)

        #expect(LibraryStore.readIndex(at: lib.locations) == nil, "launch read never throws or traps")
        let store = lib.store()
        let snapshot = await store.snapshot()
        #expect(snapshot.notebooks.map(\.id) == [entry.id])
        #expect(try Data(contentsOf: lib.locations.corruptIndexURL) == garbage)
        #expect(LibraryStore.readIndex(at: lib.locations)?.notebooks.map(\.id) == [entry.id])
    }

    @Test func newerIndexVersionRebuildsInsteadOfMisreading() async throws {
        let lib = try TempLibrary()
        let entry = try await lib.store().create(notebook("Future"))
        try FileManager.default.createDirectory(at: lib.locations.libraryDirectory, withIntermediateDirectories: true)
        try Data("{\"formatVersion\":99,\"notebooks\":[]}".utf8).write(to: lib.locations.indexURL)
        #expect(throws: LibraryError.unsupportedFormatVersion(found: 99, supported: 1)) {
            try LibraryIndex.decode(Data(contentsOf: lib.locations.indexURL))
        }
        #expect(await lib.store().snapshot().notebooks.map(\.id) == [entry.id])
    }

    @Test func explicitRebuildKeepsFoldersAndTrash() async throws {
        let lib = try TempLibrary()
        let store = lib.store()
        let folder = try await store.createFolder(named: "Physics")
        let filed = try await store.create(notebook("Filed"), in: folder.id)
        let trashed = try await store.create(notebook("Trashed"))
        try await store.delete(trashed.id)
        // A package that appeared behind the index's back (e.g. restored from backup).
        let stray = notebook("Stray")
        _ = try NotebookPackage.create(at: NotebookPackage.url(for: stray.id, in: lib.locations.notebooksDirectory), notebook: stray)

        let snapshot = await store.rebuild()
        #expect(Set(snapshot.notebooks.map(\.title)) == ["Filed", "Stray"])
        #expect(snapshot.notebook(filed.id)?.folderID == folder.id)
        #expect(snapshot.folders == [folder])
        #expect(snapshot.trash.map(\.id) == [trashed.id])
    }

    @Test func emptyContainerLoadsEmptyLibrary() async throws {
        let lib = try TempLibrary()
        let snapshot = await lib.store().load()
        #expect(snapshot.notebooks.isEmpty)
        #expect(snapshot.isComplete)
        #expect(LibraryStore.readIndex(at: lib.locations) == LibraryIndex(), "first run writes an empty index")
    }

    @Test func preloadedIndexIsNotReadAgain() async throws {
        let lib = try TempLibrary()
        let entry = try await lib.store().create(notebook("Fast"))
        let index = try #require(LibraryStore.readIndex(at: lib.locations))
        try FileManager.default.removeItem(at: lib.locations.indexURL)
        let store = LibraryStore(locations: lib.locations, preloaded: index)
        #expect(await store.snapshot().notebooks.map(\.id) == [entry.id])
    }

    @Test func readIndexHonorsByteLimit() async throws {
        let lib = try TempLibrary()
        try await lib.store().create(notebook("Big enough"))
        #expect(LibraryStore.readIndex(at: lib.locations, byteLimit: 10) == nil)
        #expect(LibraryStore.readIndex(at: lib.locations) != nil)
    }
}

private actor Partials {
    private(set) var counts: [Int] = []

    func append(_ snapshot: LibrarySnapshot) {
        #expect(!snapshot.isComplete)
        counts.append(snapshot.notebooks.count)
    }
}
