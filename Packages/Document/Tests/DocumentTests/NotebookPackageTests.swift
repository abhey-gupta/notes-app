@testable import Document
import Foundation
import InkModel
import Testing

private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

private func contents(of dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false)).sorted()
}

private func makePackage(in dir: URL, pages: Int = 3) throws -> NotebookPackage {
    let notebook = Notebook(title: "Physics", paper: .lined, pages: (0 ..< pages).map { _ in PageID() })
    return try NotebookPackage.create(
        at: NotebookPackage.url(for: notebook.id, in: NotebookPackage.notebooksDirectory(in: dir)),
        notebook: notebook
    )
}

struct NotebookPackageTests {
    @Test func locations() {
        let docs = URL(filePath: "/tmp/Docs", directoryHint: .isDirectory)
        let id = NotebookID()
        let root = NotebookPackage.notebooksDirectory(in: docs)
        #expect(root.path(percentEncoded: false) == "/tmp/Docs/Notebooks/")
        #expect(NotebookPackage.url(for: id, in: root).lastPathComponent == "\(id).nb")
        #expect(NotebookPackage.typeIdentifier == "com.abhey.notespace.notebook")
    }

    @Test func createWritesLayoutAtomically() throws {
        try withTemporaryDirectory { dir in
            let notebook = Notebook(title: "New")
            let url = NotebookPackage.url(for: notebook.id, in: NotebookPackage.notebooksDirectory(in: dir))
            let package = try NotebookPackage.create(at: url, notebook: notebook)
            #expect(try contents(of: url) == ["manifest.json", "pages", "thumbs"])
            #expect(try contents(of: url.deletingLastPathComponent()) == [url.lastPathComponent])
            #expect(package.manifest.notebook.pages.count == 1, "empty notebook gets a first page")
            #expect(package.manifest.pages[0].template == .blank)
            #expect(try NotebookPackage.open(at: url).manifest == package.manifest)
            #expect(try NotebookPackage.readManifest(at: url) == package.manifest)
            #expect(throws: DocumentError.alreadyExists(url)) { try NotebookPackage.create(at: url, notebook: notebook) }
            #expect(try NotebookPackage.packageURLs(in: url.deletingLastPathComponent())
                .map(\.lastPathComponent) == [url.lastPathComponent])
            #expect(try NotebookPackage.packageURLs(in: dir.appending(path: "nope")).isEmpty)
        }
    }

    @Test func openMissingPackage() throws {
        try withTemporaryDirectory { dir in
            let url = dir.appending(path: "missing.nb")
            #expect(throws: DocumentError.notFound(url)) { try NotebookPackage.open(at: url) }
        }
    }

    @Test func pagesRoundTripAndBumpRevs() throws {
        try withTemporaryDirectory { dir in
            var package = try makePackage(in: dir)
            let id = package.manifest.notebook.pages[1]
            var page = try package.loadPage(id)
            #expect(page.strokes.isEmpty && page.rev == 0 && page.template == PaperStyle.lined.defaultTemplate)
            #expect(!exists(package.strokesURL(for: id)), "no file until the page has ink")

            var rng = SplitMix64(seed: 9)
            try page.apply(page.addEdit(Fixtures.strokes(&rng, count: 25)))
            page.template = .grid(spacing: 16)
            let notebookRev = package.manifest.notebook.rev
            try package.savePage(page)
            #expect(package.manifest.notebook.rev == notebookRev + 1)
            #expect(package.manifest.entry(for: id)?.rev == 1)

            let reopened = try NotebookPackage.open(at: package.url)
            #expect(reopened.manifest == package.manifest)
            #expect(try reopened.loadPage(id) == page)
            #expect(try reopened.loadPage(at: 1) == page)
            #expect(throws: DocumentError.pageIndexOutOfRange(3)) { try reopened.loadPage(at: 3) }
            let stranger = PageID()
            #expect(throws: DocumentError.unknownPage(stranger)) { try reopened.loadPage(stranger) }
            #expect(try contents(of: package.pagesDirectory) == ["\(id).strokes"], "no temp files left behind")
        }
    }

    @Test func savePagesIsAllOrNothingForUnknownPages() throws {
        try withTemporaryDirectory { dir in
            var package = try makePackage(in: dir)
            let known = try package.loadPage(at: 0)
            let stranger = Page()
            #expect(throws: DocumentError.unknownPage(stranger.id)) { try package.savePages([known, stranger]) }
            #expect(try contents(of: package.pagesDirectory).isEmpty)
        }
    }

    @Test func loadIsPageScoped() throws {
        try withTemporaryDirectory { dir in
            var package = try makePackage(in: dir)
            var rng = SplitMix64(seed: 10)
            var pages = try (0 ..< 3).map { try package.loadPage(at: $0) }
            for i in pages.indices {
                try pages[i].apply(pages[i].addEdit(Fixtures.strokes(&rng, count: 5)))
            }
            try package.savePages(pages)
            // Damage pages 2 and 3; page 1 must still open without touching them.
            try Data("garbage".utf8).write(to: package.strokesURL(for: pages[1].id))
            try FileManager.default.removeItem(at: package.strokesURL(for: pages[2].id))
            let reopened = try NotebookPackage.open(at: package.url)
            #expect(try reopened.loadPage(at: 0) == pages[0])
            #expect(throws: DocumentError.corruptPage(pages[1].id, .truncated)) { try reopened.loadPage(at: 1) }
            #expect(try reopened.loadPage(at: 2).strokes.isEmpty)
        }
    }

    @Test func newerStrokeFileIsRefused() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let id = package.manifest.notebook.pages[0]
            var bytes = try [UInt8](StrokeCodec.encode([]))
            bytes[4] = 2
            try Data(bytes).write(to: package.strokesURL(for: id))
            #expect(throws: DocumentError.unsupportedFormatVersion(found: 2, supported: 1)) { try package.loadPage(id) }
        }
    }

    @Test func newerManifestIsRefusedAndLeftUntouched() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            let future = Data(#"{"formatVersion": 2}"#.utf8)
            try future.write(to: package.manifestURL)
            #expect(throws: DocumentError.unsupportedFormatVersion(found: 2, supported: 1)) { try NotebookPackage.open(at: package.url) }
            #expect(try Data(contentsOf: package.manifestURL) == future)
        }
    }

    @Test func insertDeleteReorder() throws {
        try withTemporaryDirectory { dir in
            var package = try makePackage(in: dir, pages: 2)
            let original = package.manifest.notebook.pages
            let inserted = try package.insertPage(at: 1, template: .cornell)
            let appended = try package.insertPage()
            #expect(package.manifest.notebook.pages == [original[0], inserted, original[1], appended])
            #expect(package.manifest.entry(for: inserted)?.template == .cornell)
            #expect(package.manifest.entry(for: appended)?.template == PaperStyle.lined.defaultTemplate)
            #expect(throws: DocumentError.pageIndexOutOfRange(-1)) { try package.insertPage(at: -1) }

            try package.movePage(from: 3, to: 0)
            #expect(package.manifest.notebook.pages == [appended, original[0], inserted, original[1]])

            var page = try package.loadPage(inserted)
            var rng = SplitMix64(seed: 11)
            try page.apply(page.addEdit(Fixtures.strokes(&rng, count: 2)))
            try package.savePage(page)
            for file in [package.journalURL(for: inserted), package.thumbnailURL(for: inserted), package.coverThumbnailURL] {
                try Data([1]).write(to: file)
            }
            try package.deletePage(inserted)
            #expect(package.manifest.notebook.pages == [appended, original[0], original[1]])
            #expect(try contents(of: package.pagesDirectory).isEmpty)
            #expect(try contents(of: package.thumbnailsDirectory) == ["cover.heic"])
            #expect(throws: DocumentError.unknownPage(inserted)) { try package.deletePage(inserted) }
            #expect(try NotebookPackage.open(at: package.url).manifest == package.manifest)
        }
    }

    @Test func unknownKeysSurvivePackageEdits() throws {
        try withTemporaryDirectory { dir in
            let package = try makePackage(in: dir)
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: package.manifestURL)) as? [String: Any])
            object["future"] = ["a": 1]
            var pages = try #require(object["pages"] as? [[String: Any]])
            pages[0]["futurePageKey"] = "kept"
            object["pages"] = pages
            try JSONSerialization.data(withJSONObject: object).write(to: package.manifestURL)

            var reopened = try NotebookPackage.open(at: package.url)
            try reopened.updateNotebook { $0.title = "Renamed" }
            var page = try reopened.loadPage(at: 0)
            var rng = SplitMix64(seed: 12)
            try page.apply(page.addEdit(Fixtures.strokes(&rng, count: 1)))
            try reopened.savePage(page)
            try reopened.insertPage(at: 0)

            let final = try NotebookPackage.open(at: package.url).manifest
            #expect(final.notebook.title == "Renamed")
            #expect(final.extra["future"] == .object(["a": .integer(1)]))
            #expect(final.pages[1].extra["futurePageKey"] == .string("kept"))
            #expect(final.pages[1].rev == 1)
        }
    }

    @Test func atomicWriteReplacesWithoutLeftovers() throws {
        try withTemporaryDirectory { dir in
            let file = dir.appending(path: "x.bin")
            try NotebookPackage.writeAtomically(Data([1, 2, 3]), to: file)
            try NotebookPackage.writeAtomically(Data([4]), to: file)
            #expect(try Data(contentsOf: file) == Data([4]))
            #expect(try contents(of: dir) == ["x.bin"])
            let missingDir = dir.appending(path: "nope/x.bin")
            #expect {
                try NotebookPackage.writeAtomically(Data([1]), to: missingDir)
            } throws: { error in
                if case .io = error as? DocumentError {
                    true
                } else {
                    false
                }
            }
        }
    }
}
