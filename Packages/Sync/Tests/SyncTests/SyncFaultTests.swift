import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Testing

/// What providers do to a folder (#225): late arrivals, evicted files, partial listings, a lost state file.
@Suite(.timeLimit(.minutes(2)))
struct SyncFaultTests {
    @Test func entrySeenBeforeItsBlobIsRetriedNextPull() async throws {
        let folder = try TempFolder()
        let a = Device("A", folder: folder)
        let b = Device("B", folder: folder)
        let entry = try await a.store.create(notebook("A"))
        try await a.ink(entry.id, page: 0)
        b.fs.hold("blobs/")
        try await a.sync()

        let first = try await b.engine.pull()
        #expect(first.waiting == [entry.id] && first.applied.isEmpty)
        #expect(await b.store.snapshot().notebooks.isEmpty, "never a partial notebook")
        b.fs.release("blobs/")
        let second = try await b.engine.pull()
        #expect(second.applied == [entry.id])
        #expect(try await b.strokes(entry.id, page: 0) == a.strokes(entry.id, page: 0))
    }

    @Test func evictedBlobIsDownloadedThenApplied() async throws {
        let folder = try TempFolder()
        let a = Device("A", folder: folder)
        let b = Device("B", folder: folder)
        let entry = try await a.store.create(notebook("A"))
        try await a.ink(entry.id, page: 0)
        try await a.sync()
        b.fs.evict("blobs/")

        #expect(try await b.engine.pull().waiting == [entry.id])
        #expect(b.fs.downloadRequests.contains { $0.hasPrefix("blobs/\(entry.id)/pages/") })
        #expect(try await b.engine.pull().applied == [entry.id])
    }

    @Test func gapInALogWaitsForTheMissingEntry() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        try await a.store.rename(id, to: "One")
        try await a.engine.push()
        try await a.store.rename(id, to: "Two")
        try await a.engine.push()
        b.fs.hold("log/\(a.id)/0000000002.json")
        b.fs.dropOnce("0000000003.json")

        #expect(try await b.engine.pull().applied.isEmpty)
        #expect(await b.store.snapshot().notebook(id)?.title == "Thermodynamics")
        b.fs.release("log/\(a.id)/0000000002.json")
        #expect(try await b.engine.pull().applied == [id])
        #expect(await b.store.snapshot().notebook(id)?.title == "Two")
    }

    @Test func corruptStateResendsEverythingWithoutDuplicates() async throws {
        let pair = try await Pair.make()
        let a = pair.a, b = pair.b, id = pair.id
        try Data("{ damaged".utf8).write(to: a.stateURL)
        a.relaunch()
        let (_, pushed) = try await a.sync()
        #expect(pushed.pages == 2, "full re-push")
        let (pulled, _) = try await b.sync()
        #expect(pulled.conflicts.isEmpty)
        let snapshot = await b.store.snapshot()
        #expect(snapshot.notebooks.map(\.id) == [id] && snapshot.folders.count == 1)
        #expect(try await b.strokes(id, page: 0) == a.strokes(id, page: 0))
        let (_, again) = try await a.sync()
        #expect(again.written.isEmpty, "state rewritten")
    }
}
