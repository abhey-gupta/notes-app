import CoreGraphics
@testable import Document
import Foundation
import InkModel
import Testing

/// Crash recovery: journal replay after kills, torn writes and corruption (ARCHITECTURE.md §4.4).
struct RecoveryTests {
    @Test func killAfterEveryAppendRecoversEveryEdit() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            var rng = SplitMix64(seed: 10)
            var expected = try package.loadPage(id)
            for i in 1 ... 100 {
                expected = try await session(package.url) { store in
                    let current = try await store.page(id)
                    #expect(current == expected, "reopen \(i) differs")
                    let edit: PageEdit = switch i % 10 {
                    case 3 where !current.strokes.isEmpty: try current.removeEdit([current.strokes[0].id])
                    case 7 where !current.strokes.isEmpty: try current.recolorEdit(
                            [current.strokes[current.strokes.count - 1].id],
                            to: .semantic(.red)
                        )
                    case 9 where !current.strokes.isEmpty:
                        try current.transformEdit([current.strokes[0].id], by: CGAffineTransform(translationX: 3, y: -2))
                    default: current.addEdit([Fixtures.stroke(&rng, samples: 30)])
                    }
                    try await store.apply(edit, to: id)
                    return try await store.page(id)
                }
            }
            let final = try await session(package.url) { try await $0.page(id) }
            #expect(final == expected)
            #expect(final.rev == 100)
        }
    }

    @Test func tornLastRecordAtEveryByteOffsetIsTruncated() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 11)
            let (before, after) = try await session(package.url) { store in
                for _ in 0 ..< 5 {
                    try await store.apply(addEdit(store, id, &rng), to: id)
                }
                let before = try await store.page(id)
                try await store.apply(addEdit(store, id, &rng, samples: 5), to: id)
                return try await (before, store.page(id))
            }
            let full = try Data(contentsOf: wal)
            let lastStart = try #require(Journal.scan(full).recordEnds.dropLast().last)
            for cut in lastStart ... full.count {
                try full.prefix(cut).write(to: wal)
                let page = try await session(package.url) { try await $0.page(id) }
                if cut == full.count {
                    #expect(page == after)
                    #expect(try Data(contentsOf: wal) == full)
                } else {
                    #expect(page == before, "cut at \(cut)")
                    #expect(try Data(contentsOf: wal).count == lastStart, "torn tail cut off at \(cut)")
                }
            }
        }
    }

    @Test func tornHeaderDiscardsJournal() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 12)
            try await session(package.url) { store in try await store.apply(addEdit(store, id, &rng), to: id) }
            let full = try Data(contentsOf: wal)
            for cut in 1 ..< Journal.headerLength {
                try full.prefix(cut).write(to: wal)
                let page = try await session(package.url) { try await $0.page(id) }
                #expect(try page == (package.loadPage(id)))
                #expect(!fileExists(wal))
            }
        }
    }

    @Test func corruptMiddleKeepsValidPrefixAndKeepsWorking() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 13)
            var states: [Page] = []
            try await session(package.url) { store in
                for _ in 0 ..< 6 {
                    try await store.apply(addEdit(store, id, &rng), to: id)
                    try await states.append(store.page(id))
                }
            }
            var data = try Data(contentsOf: wal)
            let ends = try Journal.scan(data).recordEnds
            data[ends[2] + 20] ^= 0xFF // inside record 3's payload
            try data.write(to: wal)

            let (recovered, extended) = try await session(package.url) { store in
                let recovered = try await store.page(id)
                try await store.apply(addEdit(store, id, &rng), to: id)
                return try await (recovered, store.page(id))
            }
            #expect(recovered == states[2])
            #expect(try Journal.scan(Data(contentsOf: wal)).damage == nil, "damaged tail replaced by the new append")
            #expect(try await session(package.url) { try await $0.page(id) } == extended)
        }
    }

    @Test func replayIsIdempotent() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 14)
            let expected = try await session(package.url) { store in
                for _ in 0 ..< 3 {
                    try await store.apply(addEdit(store, id, &rng), to: id)
                }
                let page = try await store.page(id)
                try await store.apply(page.transformEdit([page.strokes[0].id], by: CGAffineTransform(scaleX: 2, y: 2)), to: id)
                return try await store.page(id)
            }
            let journal = try Data(contentsOf: wal)
            let first = try await session(package.url) { try await $0.page(id) }
            let second = try await session(package.url) { try await $0.page(id) }
            #expect(first == expected)
            #expect(second == expected)
            #expect(try Data(contentsOf: wal) == journal, "load never rewrites a healthy journal")
        }
    }

    @Test func crashBetweenCheckpointAndJournalDeleteDoesNotReplayTwice() async throws {
        try await withPackage { package in
            let id = package.manifest.notebook.pages[0]
            let wal = package.journalURL(for: id)
            var rng = SplitMix64(seed: 15)
            let manifestBefore = try Data(contentsOf: package.manifestURL)
            let expected = try await session(package.url) { store in
                try await store.apply(addEdit(store, id, &rng), to: id)
                let page = try await store.page(id)
                // Transforms are not idempotent: replaying this twice would move the stroke twice.
                try await store.apply(page.transformEdit([page.strokes[0].id], by: CGAffineTransform(translationX: 40, y: 0)), to: id)
                return try await store.page(id)
            }
            let journal = try Data(contentsOf: wal)
            try await session(package.url) { store in
                #expect(try await store.page(id) == expected, "replayed on load")
                try await store.flush()
            }
            #expect(!fileExists(wal))

            // Crash after the stroke file rename, before the manifest write and journal delete.
            try journal.write(to: wal)
            try manifestBefore.write(to: package.manifestURL)
            let page = try await session(package.url) { store in
                let page = try await store.page(id)
                try await store.flush()
                return page
            }
            #expect(page == expected)
            #expect(!fileExists(wal), "stale journal discarded")
            #expect(try NotebookPackage.open(at: package.url).loadPage(id) == expected, "manifest rev repaired by flush")
        }
    }
}
