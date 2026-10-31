import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Testing

/// Fresh devices, open editors, and folders that aren't (yet) sync folders (#225).
@Suite(.timeLimit(.minutes(2)))
struct SyncAdoptTests {
    @Test func freshDeviceAdoptsNotebooksAndFolders() async throws {
        let folder = try TempFolder()
        let a = Device("A", folder: folder)
        let university = try await a.store.createFolder(named: "University")
        let physics = try await a.store.createFolder(named: "Physics", in: university.id)
        let thermo = try await a.store.create(notebook("Thermodynamics", pages: 3), in: physics.id)
        let old = try await a.store.create(notebook("Old"))
        try await a.ink(thermo.id, page: 2)
        try await a.store.delete(old.id)
        try await a.sync()

        let c = Device("C", folder: folder)
        let report = try await c.engine.adoptAll()
        #expect(Set(report.applied) == [thermo.id, old.id])
        let snapshot = await c.store.snapshot()
        #expect(Set(snapshot.folders) == [university, physics])
        #expect(snapshot.notebook(thermo.id)?.folderID == physics.id)
        #expect(snapshot.trash.map(\.id) == [old.id])
        #expect(try await c.pageIDs(thermo.id) == a.pageIDs(thermo.id))
        #expect(try await c.strokes(thermo.id, page: 2) == a.strokes(thermo.id, page: 2))
        let pushed = try await c.engine.push()
        #expect(pushed.written.isEmpty, "adopted notebooks aren't sent back")
    }

    @Test func openNotebookIsDeferredUntilItsEditorCloses() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        let work = try await a.store.createFolder(named: "Work")
        try await a.ink(id, page: 0)
        try await a.store.rename(id, to: "Heat")
        try await a.store.move(id, to: work.id)
        try await a.sync()

        let before = try await b.strokes(id, page: 0)
        await b.engine.setOpenNotebooks([id])
        let pulled = try await b.engine.pull()
        #expect(pulled.deferred == [id] && pulled.applied.isEmpty)
        let entry = try #require(await b.store.snapshot().notebook(id))
        #expect(entry.folderID == work.id, "library metadata applies live")
        #expect(entry.title == "Thermodynamics")
        #expect(try await b.strokes(id, page: 0) == before)
        let pushed = try await b.engine.push()
        #expect(pushed.written.isEmpty, "nothing to send while deferred")

        let applied = try await b.engine.applyDeferred(id)
        #expect(applied.applied == [id] && applied.fromDevices == ["A"])
        #expect(try await b.strokes(id, page: 0) == a.strokes(id, page: 0))
        #expect(await b.store.snapshot().notebook(id)?.title == "Heat")
    }

    @Test func oldBackupFolderIsIgnored() async throws {
        let folder = try TempFolder()
        let old = folder.root.appending(path: "Notebooks/\(NotebookID()).nb", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Manifest(notebook: notebook("Backed up")).encoded().write(to: old.appending(path: "manifest.json"))
        try Data("{}".utf8).write(to: folder.root.appending(path: "library.json"))

        let b = Device("B", folder: folder)
        let pulled = try await b.engine.pull()
        #expect(pulled.applied.isEmpty)
        #expect(await b.store.snapshot().notebooks.isEmpty)
        _ = try await b.store.create(notebook("Mine"))
        try await b.sync()
        #expect(folder.exists("sync.json"))
        #expect(folder.exists("Notebooks/\(old.lastPathComponent)/manifest.json"), "old files are left alone")
    }

    @Test func newerFolderFormatIsRefused() async throws {
        let folder = try TempFolder()
        try SyncJSON.encode(SyncFormat(formatVersion: 99, created: Date())).write(to: folder.root.appending(path: "sync.json"))
        let b = Device("B", folder: folder)
        await #expect(throws: SyncError.newerFormat(99)) { try await b.engine.pull() }
    }

    @Test func unavailableFolder() async throws {
        let folder = try TempFolder()
        let missing = folder.root.appending(path: "Gone", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
        let bookmark = try SyncFolder.bookmark(for: missing)
        try FileManager.default.removeItem(at: missing)
        let device = Device("B", folder: folder)
        for target in [SyncFolder.bookmark(Data("not a bookmark".utf8)), .bookmark(bookmark), .url(missing)] {
            let engine = SyncEngine(
                folder: target, fileSystem: device.fs, library: device.store, device: DeviceIdentity(
                    id: device.id,
                    name: "B",
                    model: "iPad"
                ),
                stateURL: device.stateURL
            )
            await #expect(throws: SyncError.folderUnavailable) { try await engine.pull() }
        }
    }
}
