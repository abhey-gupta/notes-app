import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Testing

/// GC (#225): nothing goes before every active device has read past it and 30 days have passed.
@Suite(.timeLimit(.minutes(2)))
struct SyncGCTests {
    @Test func gcWaitsForAcksThenDeletesOldBlobsAndEntries() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        let page = try await a.pageIDs(id)[0]
        let firstBlobs = folder.files(under: "blobs/\(id)/pages/\(page)")
        #expect(firstBlobs.count == 1)
        try await a.ink(id, page: 0)
        try await a.engine.push()

        folder.clock.advance(days: 31)
        var report = try await a.engine.gc()
        #expect(report.blobs == 0, "B hasn't read the op that replaced it")
        #expect(folder.files(under: "blobs/\(id)/pages/\(page)").isSuperset(of: firstBlobs))
        #expect(folder.exists("log/\(a.id)/0000000002.json"))
        #expect(folder.exists("log/\(a.id)/snapshot.json"))

        try await b.engine.pull()
        report = try await a.engine.gc()
        #expect(report.blobs == 1)
        #expect(folder.files(under: "blobs/\(id)/pages/\(page)").isDisjoint(with: firstBlobs))
        #expect(!folder.exists("log/\(a.id)/0000000001.json") && !folder.exists("log/\(a.id)/0000000002.json"))

        let c = Device("C", folder: folder)
        try await c.engine.adoptAll()
        #expect(try await c.strokes(id, page: 0) == a.strokes(id, page: 0), "a new device reads the snapshot")
    }

    @Test func gcKeepsBlobsYoungerThanThirtyDays() async throws {
        let pair = try await Pair.make()
        let folder = pair.folder, a = pair.a, b = pair.b, id = pair.id
        try await a.ink(id, page: 0)
        try await a.engine.push()
        try await b.engine.pull()
        folder.clock.advance(days: 10)
        #expect(try await a.engine.gc().blobs == 0)
        folder.clock.advance(days: 21)
        #expect(try await a.engine.gc().blobs == 1)
    }
}
