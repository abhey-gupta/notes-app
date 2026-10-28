@testable import Document
import Foundation
import InkModel
import Testing

/// A version 1 package as a v1 build left it: v1 manifest, v1 stroke files, and (on page 0) a v1
/// journal with one more stroke on top of the stroke file.
private struct V1Package {
    let url: URL
    let pages: [PageID]
    /// Page contents including the journaled stroke.
    let expected: [PageID: [Stroke]]
    let manifestBytes: Data
    let modifiedAt: Date

    init(in dir: URL) throws {
        var rng = SplitMix64(seed: 71)
        let notebook = Notebook(title: "Old", paper: .lined, pages: (0 ..< 3).map { _ in PageID() })
        let package = try NotebookPackage.create(at: dir.appending(path: "old.nb"), notebook: notebook)
        url = package.url
        pages = notebook.pages
        var expected: [PageID: [Stroke]] = [:]
        // Pages 0 and 1 have stroke files; page 2 has none.
        for (i, id) in pages.prefix(2).enumerated() {
            let strokes = Fixtures.strokes(&rng, count: 4 + i, samples: 10)
            try StrokeCodec.encode(strokes, version: 1).write(to: package.strokesURL(for: id))
            expected[id] = strokes
        }
        let base = try Data(contentsOf: package.strokesURL(for: pages[0]))
        let page = Page(id: pages[0], strokes: expected[pages[0]] ?? [])
        let extra = Fixtures.stroke(&rng, samples: 12)
        var journal = Data(Journal.encodeHeader(Journal.Header(baseRev: 0, base: StrokesIdentity(base), version: 1)))
        try journal.append(contentsOf: Journal.encodeRecord(rev: 1, edit: page.addEdit([extra]), version: 1))
        try journal.write(to: package.journalURL(for: pages[0]))
        expected[pages[0], default: []].append(extra)
        self.expected = expected

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: package.manifestURL)) as? [String: Any])
        object["formatVersion"] = 1
        manifestBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
        try manifestBytes.write(to: package.manifestURL)
        modifiedAt = package.manifest.notebook.modifiedAt
    }
}

struct MigrationTests {
    @Test func v1PackageMigratesWithBackup() throws {
        try withTemporaryDirectory { dir in
            let old = try V1Package(in: dir)
            let strokes0 = try Data(contentsOf: old.url.appending(path: "pages/\(old.pages[0]).strokes"))
            let journal0 = try Data(contentsOf: old.url.appending(path: "pages/\(old.pages[0]).wal"))

            let package = try NotebookPackage.open(at: old.url)
            #expect(package.manifest.sourceFormatVersion == Manifest.formatVersion)
            #expect(package.manifest.notebook.modifiedAt == old.modifiedAt)

            // Backup: the v1 bytes, untouched.
            let backup = old.url.appending(path: "backup-v1")
            #expect(try Data(contentsOf: backup.appending(path: "manifest.json")) == old.manifestBytes)
            #expect(try Data(contentsOf: backup.appending(path: "pages/\(old.pages[0]).strokes")) == strokes0)
            #expect(try Data(contentsOf: backup.appending(path: "pages/\(old.pages[0]).wal")) == journal0)

            // Everything on disk is current (manifest v2, stroke files v3); the journal is folded in and gone.
            #expect(try Manifest.decode(Data(contentsOf: package.manifestURL)).sourceFormatVersion == 2)
            #expect(!fileExists(package.journalURL(for: old.pages[0])))
            #expect(!fileExists(package.strokesURL(for: old.pages[2])))
            for id in old.pages.prefix(2) {
                #expect(try StrokeCodec.version(of: Data(contentsOf: package.strokesURL(for: id))) == StrokeCodec.formatVersion)
                let page = try package.loadPage(id)
                #expect(page.strokes == old.expected[id])
                #expect(page.strokes.allSatisfy { $0.rendering == nil })
            }
            #expect(try package.loadPage(old.pages[0]).rev == 1)

            // Opening again changes nothing.
            let manifest = try Data(contentsOf: package.manifestURL)
            _ = try NotebookPackage.open(at: old.url)
            #expect(try Data(contentsOf: package.manifestURL) == manifest)
        }
    }

    @Test func interruptedMigrationResumes() throws {
        try withTemporaryDirectory { dir in
            let old = try V1Package(in: dir)
            // Crash after page 0's stroke file was rewritten (journal folded in), before the manifest.
            let package0 = try #require(old.expected[old.pages[0]])
            try StrokeCodec.encode(package0).write(to: old.url.appending(path: "pages/\(old.pages[0]).strokes"))

            let package = try NotebookPackage.open(at: old.url)
            #expect(package.manifest.sourceFormatVersion == 2)
            for id in old.pages.prefix(2) {
                #expect(try package.loadPage(id).strokes == old.expected[id]) // stale journal not replayed twice
            }
            #expect(!fileExists(package.journalURL(for: old.pages[0])))
        }
    }

    @Test func storeOpensV1PackageAndKeepsEditing() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try V1Package(in: dir)
        var rng = SplitMix64(seed: 3)
        let added = Fixtures.stroke(&rng, samples: 8, rendering: .full)
        try await session(old.url) { store in
            let id = old.pages[0]
            #expect(try await store.page(id).strokes == old.expected[id])
            try await store.apply(store.page(id).addEdit([added]), to: id)
        }
        // Killed without a flush: the v2 journal replays over the migrated stroke file.
        try await session(old.url) { store in
            let strokes = try await store.page(old.pages[0]).strokes
            #expect(strokes == (old.expected[old.pages[0]] ?? []) + [added])
        }
    }

    /// A v2 manifest over v1 files (e.g. a duplicate of a v1 notebook): the v1 journal is folded into a
    /// v2 stroke file on load, so new records never land in it.
    @Test func v1JournalUnderV2ManifestIsFoldedOnLoad() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "MigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = try V1Package(in: dir)
        var object = try #require(JSONSerialization.jsonObject(with: old.manifestBytes) as? [String: Any])
        object["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: old.url.appending(path: "manifest.json"))

        let id = old.pages[0]
        var rng = SplitMix64(seed: 4)
        let added = Fixtures.stroke(&rng, samples: 8, rendering: .square)
        try await session(old.url) { store in
            #expect(try await store.page(id).strokes == old.expected[id])
            let strokes = try Data(contentsOf: old.url.appending(path: "pages/\(id).strokes"))
            #expect(StrokeCodec.version(of: strokes) == StrokeCodec.formatVersion)
            try await store.apply(store.page(id).addEdit([added]), to: id)
        }
        let journal = try Data(contentsOf: old.url.appending(path: "pages/\(id).wal"))
        #expect(try Journal.scan(journal).header?.version == Journal.formatVersion)
        try await session(old.url) { store in
            let strokes = try await store.page(id).strokes
            #expect(strokes == (old.expected[id] ?? []) + [added])
        }
    }

    @Test func newerPackageIsRefusedWithoutBackupOrChanges() throws {
        try withTemporaryDirectory { dir in
            let old = try V1Package(in: dir)
            let future = Data(#"{"formatVersion": 99}"#.utf8)
            try future.write(to: old.url.appending(path: "manifest.json"))
            #expect(throws: DocumentError.unsupportedFormatVersion(found: 99, supported: 2)) { try NotebookPackage.open(at: old.url) }
            #expect(try Data(contentsOf: old.url.appending(path: "manifest.json")) == future)
            #expect(!fileExists(old.url.appending(path: "backup-v1")))
            #expect(fileExists(old.url.appending(path: "pages/\(old.pages[0]).wal")))
        }
    }
}
