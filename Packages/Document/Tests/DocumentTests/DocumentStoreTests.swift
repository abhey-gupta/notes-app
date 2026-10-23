import CoreGraphics
@testable import Document
import Foundation
import InkModel
import Synchronization
import Testing

struct DocumentStoreTests {
    @Test func checkpointDeletesJournalAndPreservesPage() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 16)
            let (expected, notebookRev) = try await session(package.url) { store in
                let (edits, _) = try await everyEditKind(on: store.page(id), rng: &rng)
                for edit in edits {
                    try await store.apply(edit, to: id)
                }
                #expect(fileExists(wal))
                #expect(try await store.journalSize(of: id) == Data(contentsOf: wal).count)
                try await store.flush()
                #expect(!fileExists(wal))
                #expect(await store.journalSize(of: id) == 0)
                return try await (store.page(id), store.manifest.notebook.rev)
            }
            let reopened = try NotebookPackage.open(at: package.url)
            #expect(try reopened.loadPage(id) == expected)
            #expect(reopened.manifest.entry(for: id)?.rev == expected.rev)
            #expect(notebookRev > package.manifest.notebook.rev)
            #expect(try await session(package.url) { try await $0.page(id) } == expected)
        }
    }

    @Test func checkpointsWhenJournalPassesOneMegabyte() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 17)
            let events = Mutex<[DocumentStore.Event]>([])
            let store = try DocumentStore(opening: package.url, options: .init(idleDelay: nil) { event in
                events.withLock { $0.append(event) }
            })
            var sizes: [Int] = []
            // ~48 KB per record: 2000 samples × 24 B.
            for _ in 0 ..< 30 {
                try await store.apply(addEdit(store, id, &rng, samples: 2000), to: id)
                await sizes.append(store.journalSize(of: id))
            }
            let crossing = try #require(sizes.firstIndex(of: 0))
            #expect(sizes[crossing - 1] <= 1 << 20)
            #expect(sizes[crossing - 1] + 48000 > 1 << 20, "checkpoint fires on the append that passes 1 MiB")
            #expect(sizes[crossing + 1] > 0, "next append starts a fresh journal")
            #expect(events.withLock { $0.count {
                if case .checkpointed = $0 {
                    true
                } else {
                    false
                }
            } } == 1)
            let expected = try await store.page(id)
            #expect(try await session(package.url) { try await $0.page(id) } == expected)
            #expect(fileExists(wal))
        }
    }

    @Test func idleCheckpointIsDebounced() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 18)
            let checkpoints = Mutex(0)
            let store = try DocumentStore(opening: package.url, options: .init(idleDelay: .milliseconds(400)) { event in
                if case .checkpointed = event {
                    checkpoints.withLock { $0 += 1 }
                }
            })
            for _ in 0 ..< 5 {
                try await store.apply(addEdit(store, id, &rng), to: id)
            }
            #expect(fileExists(wal))
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(10)
            while fileExists(wal), clock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(!fileExists(wal))
            #expect(checkpoints.withLock { $0 } == 1, "five quick edits, one checkpoint")
            #expect(try await NotebookPackage.open(at: package.url).loadPage(id) == (store.page(id)))
        }
    }

    @Test func evictCheckpointsAndUnloads() async throws {
        try await withPackage { package in
            let (a, b) = (package.manifest.notebook.pages[0], package.manifest.notebook.pages[1])
            var rng = SplitMix64(seed: 19)
            let store = try manualStore(package.url)
            try await store.apply(addEdit(store, a, &rng), to: a)
            try await store.apply(addEdit(store, b, &rng), to: b)
            let pageA = try await store.page(a)
            try await store.evict(page: a)
            #expect(await !store.isLoaded(a))
            #expect(await store.isLoaded(b))
            #expect(!fileExists(package.journalURL(for: a)))
            #expect(fileExists(package.journalURL(for: b)), "other pages untouched")
            #expect(try NotebookPackage.open(at: package.url).loadPage(a) == pageA)
            #expect(try await store.page(a) == pageA)
        }
    }

    @Test func concurrentEditsAcrossPages() async throws {
        try await withPackage(pages: 8) { package in
            let ids = package.manifest.notebook.pages
            let store = try manualStore(package.url)
            try await withThrowingTaskGroup { group in
                for task in 0 ..< 16 {
                    group.addTask {
                        var rng = SplitMix64(seed: UInt64(100 + task))
                        for i in 0 ..< 25 {
                            let id = ids[(task + i) % ids.count]
                            let stroke = Fixtures.stroke(&rng, samples: 16)
                            try await store.apply(.add([PlacedStroke(index: 0, stroke: stroke)]), to: id)
                            if i % 10 == 9 {
                                if task.isMultiple(of: 2) {
                                    try await store.flush()
                                } else {
                                    try await store.evict(page: id)
                                }
                            }
                        }
                    }
                }
                try await group.waitForAll()
            }
            var live: [Page] = []
            for id in ids {
                try await live.append(store.page(id))
            }
            #expect(live.reduce(0) { $0 + $1.strokes.count } == 16 * 25)
            #expect(live.reduce(0) { $0 + Int($1.rev) } == 16 * 25)
            let reopened = try await session(package.url) { store in
                var pages: [Page] = []
                for id in ids {
                    try await pages.append(store.page(id))
                }
                return pages
            }
            #expect(reopened == live)
        }
    }

    @Test func undoAndRedoThroughInverseEdits() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let store = try manualStore(package.url)
            try await store.apply(store.page(id).addEdit((0 ..< 4).map(gridStroke)), to: id)
            let original = try await store.page(id)

            var applied: [PageEdit] = []
            func run(_ make: (Page) throws -> PageEdit) async throws {
                let edit = try await make(store.page(id))
                try await store.apply(edit, to: id)
                applied.append(edit)
            }
            try await run { $0.addEdit([gridStroke(4)]) }
            try await run { try $0.recolorEdit([$0.strokes[1].id], to: .semantic(.blue)) }
            try await run { try $0.transformEdit([$0.strokes[2].id], by: CGAffineTransform(translationX: 16, y: -8)) }
            try await run { try $0.removeEdit([$0.strokes[0].id]) }
            try await run { try $0.replaceEdit([$0.strokes[0].id: [gridStroke(5), gridStroke(6)]]) }
            let edited = try await store.page(id)

            for edit in applied.reversed() {
                try await store.apply(edit.inverse(), to: id)
            }
            let undone = try await session(package.url) { try await $0.page(id) }
            #expect(undone.strokes == original.strokes)
            #expect(undone.rev == original.rev + 10)

            for edit in applied {
                try await store.apply(edit, to: id)
            }
            let redone = try await session(package.url) { try await $0.page(id) }
            #expect(redone.strokes == edited.strokes)
        }
    }

    @Test func invalidEditChangesNothing() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            var rng = SplitMix64(seed: 20)
            let store = try manualStore(package.url)
            try await store.apply(addEdit(store, id, &rng), to: id)
            let before = try await store.page(id)
            let size = await store.journalSize(of: id)
            let ghost = Fixtures.stroke(&rng, samples: 3)
            await #expect(throws: DocumentError.invalidEdit(id, .indexMismatch(index: 0, expected: ghost.id))) {
                try await store.apply(.remove([PlacedStroke(index: 0, stroke: ghost)]), to: id)
            }
            await #expect(throws: DocumentError.unknownPage(PageID(uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))))) {
                try await store.apply(
                    before.addEdit([ghost]),
                    to: PageID(uuid: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
                )
            }
            #expect(try await store.page(id) == before)
            #expect(await store.journalSize(of: id) == size)
        }
    }

    @Test func deletePageDropsItsJournal() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            var rng = SplitMix64(seed: 21)
            let store = try manualStore(package.url)
            try await store.apply(addEdit(store, id, &rng), to: id)
            try await store.deletePage(id)
            #expect(!fileExists(package.journalURL(for: id)))
            #expect(await !store.isLoaded(id))
            await #expect(throws: DocumentError.unknownPage(id)) { try await store.page(id) }
        }
    }

    /// Template changes reach the manifest at once and survive a later checkpoint and a crash of a dirty page.
    @Test func setTemplateUpdatesManifestAndLoadedPages() async throws {
        try await withPackage(pages: 3) { package in
            let ids = package.manifest.notebook.pages
            var rng = SplitMix64(seed: 23)
            try await session(package.url) { store in
                try await store.apply(addEdit(store, ids[0], &rng), to: ids[0])
                try await store.setTemplate(.grid(spacing: 16), for: [ids[0], ids[1]])
                #expect(try await store.page(ids[0]).template == .grid(spacing: 16))
                #expect(try await store.page(ids[1]).template == .grid(spacing: 16))
                #expect(try await store.page(ids[2]).template == .lined(spacing: 24))
                let manifest = try NotebookPackage.readManifest(at: package.url)
                #expect(manifest.entry(for: ids[1])?.template == .grid(spacing: 16))
                #expect(manifest.entry(for: ids[2])?.template == .lined(spacing: 24))
            }
            // Dropped without a flush: page 0's ink comes back from its journal, the template from the manifest.
            let reopened = try manualStore(package.url)
            let page = try await reopened.page(ids[0])
            #expect(page.template == .grid(spacing: 16))
            #expect(page.strokes.count == 1)
            try await reopened.setTemplate(.dotted(spacing: 20))
            try await reopened.flush()
            #expect(try NotebookPackage.open(at: package.url).manifest.pages.allSatisfy { $0.template == .dotted(spacing: 20) })
            let stranger = PageID()
            await #expect(throws: DocumentError.unknownPage(stranger)) { try await reopened.setTemplate(.blank, for: [stranger]) }
        }
    }
}
