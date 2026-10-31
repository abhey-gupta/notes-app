import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Testing

/// The folder format and the pure merge (#225): names, op JSON, last-writer-wins, tombstones, log folding.
struct SyncFormatTests {
    private let nb = NotebookID()
    private let page = PageID()
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func op(_ clock: UInt64, _ change: SyncChange) -> SyncOp {
        SyncOp(clock: clock, at: at, change)
    }

    @Test func namesSortByClockAndSeq() {
        #expect(SyncLayout.entry(42, of: "D") == "log/D/0000000042.json")
        #expect(SyncLayout.seq(ofEntry: "0000000042.json") == 42)
        #expect(SyncLayout.seq(ofEntry: "snapshot.json") == nil)
        let name = SyncLayout.blobName(clock: 7, device: "AB-CD", ext: "strokes")
        #expect(name == "000000000007-AB-CD.strokes")
        #expect(SyncLayout.device(ofBlob: name) == "AB-CD")
        #expect(SyncLayout.asset(SyncAsset(kind: .backgrounds, name: "x.pdf"), notebook: nb) == "blobs/\(nb)/backgrounds/x.pdf")
    }

    @Test func opsRoundTripAndUnknownOpsAreSkipped() throws {
        let ops = [
            op(1, .notebookSet(nb, fields: ["title": .string("A"), "folder": .null])),
            op(2, .pageSet(nb, page: page, base: 1, entry: PageMeta(template: .lined(spacing: 24)), strokes: "b")),
            op(
                3,
                .pageSet(nb, page: page, base: 2, entry: PageMeta(template: .blank, background: .pdf(file: "f.pdf", page: 1)), strokes: nil)
            ),
            op(4, .pageRemove(nb, page: page)),
            op(5, .coverSet(nb, blob: "c")),
            op(6, .assetAdd(nb, SyncAsset(kind: .images, name: "i.heic"))),
            op(7, .lifecycle(nb, .trash)), op(8, .lifecycle(nb, .restore)), op(9, .lifecycle(nb, .delete)),
            op(10, .folderSet(FolderID(), fields: ["name": .string("F"), "parent": .null])), op(11, .folderRemove(FolderID())),
        ]
        let entry = LogEntry(seq: 1, device: "D", writtenAt: at, ops: ops)
        let data = try SyncJSON.encode(entry)
        #expect(SyncJSON.decode(LogEntry.self, from: data) == entry)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""op":"pageSet""#))

        let newer = #"{"seq":2,"device":"D","writtenAt":0,"ops":[{"op":"stickerAdd","clock":3,"at":0}]}"#
        let decoded = try #require(SyncJSON.decode(LogEntry.self, from: Data(newer.utf8)))
        #expect(decoded.ops.map(\.change) == [.unknown("stickerAdd")])
    }

    @Test func laterStampWinsPerFieldTiesByDevice() {
        var state = SyncState(folder: "/f", deviceId: "me")
        _ = Apply.apply(op(5, .notebookSet(nb, fields: ["title": .string("A"), "cover": .string("navy")])), from: "x", to: &state)
        _ = Apply.apply(op(4, .notebookSet(nb, fields: ["title": .string("old")])), from: "y", to: &state)
        _ = Apply.apply(op(6, .notebookSet(nb, fields: ["cover": .string("sage")])), from: "y", to: &state)
        _ = Apply.apply(op(5, .notebookSet(nb, fields: ["title": .string("B")])), from: "z", to: &state)
        let record = try? #require(state.notebooks[nb])
        #expect(record?[.title]?.value == .string("B"), "same clock: the larger device ID wins")
        #expect(record?[.cover]?.value == .string("sage"))
        #expect(state.clock == 6)
        #expect(record?.from == ["x", "y", "z"])
    }

    @Test func mergeIsOrderIndependent() {
        let ops: [(SyncOp, String)] = [
            (op(1, .notebookSet(nb, fields: ["title": .string("A")])), "x"),
            (op(2, .pageSet(nb, page: page, base: 0, entry: PageMeta(template: .blank), strokes: "1")), "x"),
            (op(3, .pageSet(nb, page: page, base: 2, entry: PageMeta(template: .blank), strokes: "2")), "y"),
            (op(3, .pageRemove(nb, page: page)), "x"),
            (op(4, .notebookSet(nb, fields: ["title": .string("B")])), "y"),
        ]
        var forward = SyncState(folder: "/f", deviceId: "me")
        var backward = forward
        for (op, device) in ops {
            _ = Apply.apply(op, from: device, to: &forward)
        }
        for (op, device) in ops.reversed() {
            _ = Apply.apply(op, from: device, to: &backward)
        }
        #expect(forward.notebooks[nb]?.pages[page]?.blob == "2")
        #expect(forward.notebooks[nb]?.pages == backward.notebooks[nb]?.pages)
        #expect(forward.notebooks[nb]?.fields == backward.notebooks[nb]?.fields)
    }

    @Test func tombstoneWinsUnlessALaterOpBringsItBackToTheRoot() {
        let folder = NotebookField.value(of: FolderID())
        var state = SyncState(folder: "/f", deviceId: "me")
        _ = Apply.apply(op(1, .notebookSet(nb, fields: ["title": .string("A"), "folder": folder])), from: "x", to: &state)
        _ = Apply.apply(op(2, .lifecycle(nb, .trash)), from: "x", to: &state)
        _ = Apply.apply(op(3, .lifecycle(nb, .delete)), from: "x", to: &state)
        #expect(state.notebooks[nb]?.isDeleted == true)
        _ = Apply.apply(op(4, .pageSet(nb, page: page, base: 0, entry: PageMeta(template: .blank), strokes: "s")), from: "y", to: &state)
        let record = state.notebooks[nb]
        #expect(record?.isDeleted == false)
        #expect(record?.folder == nil && record?.isTrashed == false)
    }

    @Test func pageWrittenWithoutSeeingTheShownVersionMarksItReplaced() {
        var state = SyncState(folder: "/f", deviceId: "me")
        _ = Apply.apply(op(1, .pageSet(nb, page: page, base: 0, entry: PageMeta(template: .blank), strokes: "v1")), from: "x", to: &state)
        let shown = state.notebooks[nb]?.pages[page]?.stamp
        state.notebooks[nb]?.pages[page]?.local = shown.map { LocalPage(stamp: $0, rev: 1, blob: "v1") }
        _ = Apply.apply(op(2, .pageSet(nb, page: page, base: 1, entry: PageMeta(template: .blank), strokes: "v2")), from: "x", to: &state)
        #expect(state.notebooks[nb]?.pages[page]?.replaced == nil, "built on the shown version")
        let v2 = state.notebooks[nb]?.pages[page]?.stamp
        state.notebooks[nb]?.pages[page]?.local = v2.map { LocalPage(stamp: $0, rev: 2, blob: "v2") }
        _ = Apply.apply(op(3, .pageSet(nb, page: page, base: 1, entry: PageMeta(template: .blank), strokes: "v3")), from: "y", to: &state)
        #expect(state.notebooks[nb]?.pages[page]?.replaced == "v2")
    }

    @Test func foldKeepsTheLatestOpPerThing() {
        let ops = [
            op(1, .notebookSet(nb, fields: ["title": .string("A"), "cover": .string("navy")])),
            op(2, .pageSet(nb, page: page, base: 0, entry: PageMeta(template: .blank), strokes: "1")),
            op(3, .notebookSet(nb, fields: ["title": .string("B")])),
            op(4, .pageSet(nb, page: page, base: 2, entry: PageMeta(template: .blank), strokes: "2")),
        ]
        let folded = SyncEngine.fold(ops)
        #expect(folded.map(\.clock) == [1, 3, 4])
        var all = SyncState(folder: "/f", deviceId: "me")
        var compact = all
        for op in ops {
            _ = Apply.apply(op, from: "x", to: &all)
        }
        for op in folded {
            _ = Apply.apply(op, from: "x", to: &compact)
        }
        #expect(all.notebooks == compact.notebooks)
    }

    @Test func pageOrderKeepsLocalPagesAndOrphans() {
        let (p1, p2, p3, local, orphan) = (PageID(), PageID(), PageID(), PageID(), PageID())
        var record = NotebookRecord()
        record[.pages] = Field(stamp: Stamp(clock: 1, device: "x"), value: .array([p1, p2, p3].map { .string($0.description) }), local: nil)
        for page in [p1, p2, p3, orphan] {
            record.pages[page] = PageRecord(
                stamp: Stamp(clock: 1, device: "x"), base: 0, blob: nil, meta: PageMeta(template: .blank), removed: page == p3
            )
        }
        let order = SyncEngine.order(record, local: [p1, local, p2], keep: [local])
        #expect(order == [p1, local, p2, orphan])
    }

    @Test func stateRoundTripsAndIsDroppedForAnotherFolder() throws {
        var state = SyncState(folder: "/f", deviceId: "me")
        _ = Apply.apply(op(1, .notebookSet(nb, fields: ["title": .string("A")])), from: "x", to: &state)
        _ = Apply.apply(op(2, .folderSet(FolderID(), fields: ["name": .string("F")])), from: "x", to: &state)
        state.deferred = [nb]
        let url = FileManager.default.temporaryDirectory.appending(path: "sync-state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try state.save(to: url)
        #expect(SyncState.load(from: url, folder: "/f", deviceId: "me") == state)
        #expect(SyncState.load(from: url, folder: "/other", deviceId: "me").notebooks.isEmpty)
        #expect(SyncState.load(from: url, folder: "/f", deviceId: "you").notebooks.isEmpty)
    }

    @Test func deviceIDIsMadeOnce() throws {
        let defaults = try #require(UserDefaults(suiteName: "SyncTests-\(UUID().uuidString)"))
        let first = DeviceIdentity.current(name: "iPad", model: "iPad", defaults: defaults)
        #expect(UUID(uuidString: first.id) != nil)
        #expect(DeviceIdentity.current(name: "Renamed", model: "iPad", defaults: defaults).id == first.id)
    }

    @Test func folderNamesShowTheProvider() {
        let icloud = URL(
            filePath: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/Notespace",
            directoryHint: .isDirectory
        )
        #expect(SyncFolder.displayName(for: icloud) == "iCloud Drive › Notespace")
        #expect(SyncFolder.displayName(for: URL(filePath: "/x/File Provider Storage/Sync", directoryHint: .isDirectory)) == "Sync")
    }
}

struct FileStampTests {
    @Test func stampSurvivesTheStateFileRoundTrip() throws {
        let stamp = FileStamp(modified: Date(timeIntervalSince1970: 1_793_458_846.996_404), size: 34121)
        let decoded = try #require(SyncJSON.decode(FileStamp.self, from: SyncJSON.encode(stamp)))
        #expect(decoded == stamp)
        let twice = try #require(SyncJSON.decode(FileStamp.self, from: SyncJSON.encode(decoded)))
        #expect(twice == stamp)
    }
}
