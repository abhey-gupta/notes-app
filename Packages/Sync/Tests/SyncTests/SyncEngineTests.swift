import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Testing

/// Two devices on one folder (#225): what a push sends, how a pull merges.
@Suite(.timeLimit(.minutes(2)))
struct SyncEngineTests {
    @Test func firstPushAndPullRoundTrip() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id, physics = pair.physics
        #expect(folder.exists("sync.json"))
        #expect(folder.exists("devices/\(a.id).json") && folder.exists("devices/\(b.id).json"))

        let entry = try #require(await b.store.snapshot().notebook(id))
        #expect(entry.title == "Thermodynamics" && entry.folderID == physics && entry.pageCount == 2)
        #expect(await b.store.snapshot().folders.map(\.name) == ["Physics"])
        #expect(try await b.pageIDs(id) == a.pageIDs(id))
        #expect(try await b.strokes(id, page: 0) == a.strokes(id, page: 0))
        #expect(try await b.strokes(id, page: 1) == nil)
        let bPackage = try await b.package(id)
        #expect(LocalScan.assets(in: bPackage.url).count == 1)
        #expect(try Data(contentsOf: bPackage.coverThumbnailURL) == Data("cover".utf8))
        #expect(entry.coverThumbnailPath != nil)

        let (pulled, pushed) = try await b.sync()
        #expect(pulled.applied.isEmpty && pushed.written.isEmpty, "B has nothing to send back")
        let (again, _) = try await a.sync()
        #expect(again.applied.isEmpty, "A gets nothing back")
    }

    @Test func editingOnePageSendsOneBlobAndOneEntry() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        try await a.ink(id, page: 1)
        let page = try await a.pageIDs(id)[1]
        let pushed = try await a.engine.push()
        let written = relative(pushed.written, to: folder)
        #expect(written.count == 2)
        #expect(written.contains("log/\(a.id)/0000000002.json"))
        #expect(written.contains { $0.hasPrefix("blobs/\(id)/pages/\(page)/") && $0.hasSuffix("-\(a.id).strokes") })
        #expect(pushed.pages == 1)

        let before = try await b.strokes(id, page: 0)
        let pulled = try await b.engine.pull()
        #expect(pulled.applied == [id] && pulled.fromDevices == ["A"])
        #expect(try await b.strokes(id, page: 1) == a.strokes(id, page: 1))
        #expect(try await b.strokes(id, page: 0) == before)
    }

    @Test func renameOnOneDeviceAndMoveOnTheOtherBothSurvive() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        try await a.store.rename(id, to: "Heat")
        let work = try await b.store.createFolder(named: "Work")
        try await b.store.move(id, to: work.id)
        try await a.engine.push()
        try await b.engine.push()
        try await a.sync()
        try await b.sync()
        try await a.sync()
        for device in [a, b] {
            let entry = try #require(await device.store.snapshot().notebook(id))
            #expect(entry.title == "Heat", "\(device.name)")
            #expect(entry.folderID == work.id, "\(device.name)")
        }
        #expect(await a.store.snapshot().folders.contains { $0.id == work.id && $0.name == "Work" })
    }

    @Test func samePageOnBothSidesIsAConflictKeepMineConverges() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        try await a.ink(id, page: 0)
        try await b.ink(id, page: 0)
        let mine = try await b.strokes(id, page: 0)
        try await a.sync()
        let (pulled, _) = try await b.sync()
        let theirs = try await a.strokes(id, page: 0)
        #expect(try await b.strokes(id, page: 0) == theirs, "the later puller shows the other version")
        let conflict = try #require(pulled.conflicts.first)
        #expect(pulled.conflicts.count == 1 && conflict.device == a.id)
        #expect(try await b.engine.conflicts() == [conflict])
        #expect(try await a.engine.conflicts().isEmpty)

        try await b.engine.keepMine(notebook: id, page: conflict.page)
        #expect(try await b.strokes(id, page: 0) == mine)
        #expect(try await b.engine.conflicts().isEmpty)
        let (back, _) = try await a.sync()
        #expect(back.conflicts.isEmpty, "Keep mine builds on the version A shows")
        #expect(try await a.strokes(id, page: 0) == mine)
        try await b.sync()
        #expect(try await b.strokes(id, page: 0) == mine)
    }

    @Test func editAfterDeleteBringsTheNotebookBackToTheRoot() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        try await a.store.delete(id)
        try await a.engine.push() // the trash goes out within seconds; the purge comes 30 days later
        try await a.store.purgeTrash(now: folder.clock.now.addingTimeInterval(31 * 86400))
        try await a.engine.push()
        // Three edits: B's clock ends past A's two ops (trash, tombstone), so "later" never comes down to a tie.
        for _ in 0 ..< 3 {
            try await b.ink(id, page: 1)
            try await b.engine.push()
        }

        try await a.sync()
        let back = try #require(await a.store.snapshot().notebook(id))
        #expect(back.folderID == nil && back.pageCount == 2)
        #expect(try await a.strokes(id, page: 0) == b.strokes(id, page: 0))
        #expect(try await a.strokes(id, page: 1) == b.strokes(id, page: 1))
        try await b.sync()
        #expect(await b.store.snapshot().notebook(id)?.folderID == nil)
    }

    @Test func deleteWithoutLaterEditsWins() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        try await b.ink(id, page: 1)
        try await b.engine.push()
        try await a.store.delete(id)
        try await a.engine.push() // the trash goes out within seconds; the purge comes 30 days later
        try await a.store.purgeTrash(now: folder.clock.now.addingTimeInterval(31 * 86400))
        try await a.sync()
        try await b.sync()
        #expect(await b.store.snapshot().notebook(id) == nil)
        #expect(await a.store.snapshot().notebook(id) == nil)
    }

    @Test func trashRestoreAndPurgeFollowAcrossDevices() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        try await a.store.delete(id)
        try await a.sync()
        try await b.sync()
        #expect(await b.store.snapshot().notebook(id) == nil)
        #expect(await b.store.snapshot().trash.map(\.id) == [id])

        try await a.store.restore(id)
        try await a.sync()
        try await b.sync()
        #expect(await b.store.snapshot().notebook(id) != nil)
        #expect(await b.store.snapshot().trash.isEmpty)

        try await a.store.delete(id)
        try await a.engine.push() // the trash goes out within seconds; the purge comes 30 days later
        try await a.store.purgeTrash(now: folder.clock.now.addingTimeInterval(31 * 86400))
        try await a.sync()
        try await b.sync()
        let snapshot = await b.store.snapshot()
        #expect(snapshot.notebook(id) == nil && snapshot.trash.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: b.locations.trashDirectory.appending(path: "\(id).nb").path(percentEncoded: false)))
    }

    /// A live notebook that vanishes without passing through the trash (a rebuild skipped its unreadable
    /// package) is never sent as a delete: the other device keeps it.
    @Test func liveNotebookMissingFromTheLibraryIsNotADelete() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        try await a.store.purge(id)
        try await a.sync()
        try await b.sync()
        #expect(await b.store.snapshot().notebook(id) != nil)
    }

    @Test func folderRenameAndRemovePropagate() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id, physics = pair.physics
        try await a.store.renameFolder(physics, to: "Science")
        try await a.sync()
        try await b.sync()
        #expect(await b.store.snapshot().folders.map(\.name) == ["Science"])

        try await a.store.move(id, to: nil)
        try await a.store.deleteFolder(physics)
        try await a.sync()
        try await b.sync()
        let snapshot = await b.store.snapshot()
        #expect(snapshot.folders.isEmpty)
        #expect(snapshot.notebook(id)?.folderID == nil, "moved out before the folder went: not trashed")
    }

    @Test func devicesListsThisDeviceFirst() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b
        let devices = try await b.engine.devices()
        #expect(devices.map(\.id) == [b.id, a.id])
        #expect(devices.map(\.name) == ["B", "A"])
        #expect(devices.last?.applied[b.id] == nil && devices.first?.applied[a.id] == 1)
    }
}
