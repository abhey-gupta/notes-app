import Document
@testable import FixtureGen
import Foundation
import InkModel
import Testing

/// Fresh temp directory, removed when the closure returns.
private func withTemporaryDirectory<R>(_ body: (URL) async throws -> R) async throws -> R {
    let dir = FileManager.default.temporaryDirectory.appending(path: "FixtureGenTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

/// Relative path → bytes of every file under `root`.
private func snapshot(_ root: URL) throws -> [String: Data] {
    let fm = FileManager.default
    var files: [String: Data] = [:]
    for path in try fm.subpathsOfDirectory(atPath: root.path(percentEncoded: false)) {
        let url = root.appending(path: path)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue {
            files[path] = try Data(contentsOf: url)
        }
    }
    return files
}

struct FixtureGenTests {
    @Test func packageOpensWithNotebookPackageAndDocumentStore() async throws {
        try await withTemporaryDirectory { dir in
            let generator = FixtureGenerator(FixtureSpec(pages: 4, seed: 3, theme: .night))
            let url = dir.appending(path: generator.defaultPackageName)
            let report = try generator.write(to: url)
            #expect(url.lastPathComponent == "4-pages.nb")

            let package = try NotebookPackage.open(at: url)
            #expect(package.manifest == report.package.manifest)
            #expect(package.manifest.notebook == generator.notebook)
            #expect(package.manifest.notebook.theme == .night)
            #expect(package.manifest.pages.count == 4)
            var strokes = 0
            var samples = 0
            for i in 0 ..< 4 {
                let page = try package.loadPage(at: i)
                #expect(page == generator.page(at: i))
                #expect(package.manifest.pages[i].template == page.template)
                strokes += page.strokes.count
                samples += page.strokes.reduce(0) { $0 + $1.samples.count }
            }
            #expect(report.strokes == strokes && report.samples == samples)
            #expect(report.bytes > samples * 24, "raw samples barely compress")

            let store = try DocumentStore(opening: url, options: .init(idleDelay: nil))
            let id = package.manifest.notebook.pages[2]
            var page = try await store.page(id)
            #expect(page == generator.page(at: 2))
            let extra = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: [Sample(x: 10, y: 10), Sample(x: 20, y: 12, t: 0.01)])
            try await store.apply(page.addEdit([extra]), to: id)
            try await store.flush()
            try page.apply(page.addEdit([extra]))
            #expect(try NotebookPackage.open(at: url).loadPage(id) == page)
        }
    }

    @Test func sameSeedGivesIdenticalBytes() async throws {
        try await withTemporaryDirectory { dir in
            let spec = FixtureSpec(pages: 3, seed: 42)
            let a = dir.appending(path: "a/x.nb")
            let b = dir.appending(path: "b/x.nb")
            let c = dir.appending(path: "c/x.nb")
            try FixtureGenerator(spec).write(to: a)
            try FixtureGenerator(spec).write(to: b)
            var other = spec
            other.seed = 43
            try FixtureGenerator(other).write(to: c)
            let first = try snapshot(a)
            #expect(first.count == 4, "manifest + 3 stroke files")
            #expect(try first == snapshot(b))
            #expect(try first != snapshot(c))
        }
    }

    /// ARCHITECTURE.md §12: ~400 strokes/page, ~60 samples/stroke.
    @Test func densityWithinSpec() {
        let generator = FixtureGenerator(FixtureSpec(pages: 12, seed: 1))
        let pages = Array(generator.pages)
        let counts = pages.map(\.strokes.count)
        let strokes = pages.flatMap(\.strokes)
        let samples = strokes.map(\.samples.count)
        let meanStrokes = Double(strokes.count) / Double(pages.count)
        let meanSamples = Double(samples.reduce(0, +)) / Double(strokes.count)
        #expect((360 ... 440).contains(meanStrokes), "mean strokes/page \(meanStrokes)")
        #expect(counts.allSatisfy { (340 ... 460).contains($0) }, "strokes/page \(counts)")
        #expect((54 ... 70).contains(meanSamples), "mean samples/stroke \(meanSamples)")
        #expect(samples.allSatisfy { (4 ... 200).contains($0) })
        // Mostly word-sized strokes, plus short i-dots/t-bars/bullets.
        let wordSized = samples.filter { (30 ... 160).contains($0) }.count
        #expect(Double(wordSized) / Double(samples.count) > 0.6)
        #expect(strokes.contains { $0.tool == .highlighter })
        #expect(Set(strokes.map(\.tool)).count >= 2)
        #expect(Set(strokes.map(\.color)).count >= 3)
    }

    @Test func strokesAreHandwritingLike() {
        let page = FixtureGenerator(FixtureSpec(pages: 1, seed: 5)).page(at: 0)
        let size = Notebook.a4Portrait
        for stroke in page.strokes {
            let s = stroke.samples
            #expect(s.allSatisfy { $0.x >= 0 && $0.x <= Float(size.width) && $0.y >= 0 && $0.y <= Float(size.height) })
            #expect(s.allSatisfy { (0.02 ... 1).contains($0.force) && $0.altitude > 0 && $0.altitude <= .pi / 2 })
            #expect(zip(s, s.dropFirst()).allSatisfy { $0.t < $1.t }, "time increases")
            // Smooth: consecutive samples stay close (a random walk or teleport would not).
            let maxStep = zip(s, s.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max() ?? 0
            #expect(maxStep < 12, "max step \(maxStep) pt")
        }
        // Text sits in lines: most word strokes are wider than tall-ish and short.
        let words = page.strokes.filter { $0.tool != .highlighter && $0.samples.count >= 30 }
        let lineSized = words.filter { $0.bounds.width < 160 && $0.bounds.height < 60 }.count
        #expect(Double(lineSized) / Double(words.count) > 0.9)
        let ids = page.strokes.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count, "UUIDv7s in drawing order")
    }

    @Test func strokesPerPageOption() {
        for k in [0, 50, 1200] {
            let generator = FixtureGenerator(FixtureSpec(pages: 2, seed: 9, strokesPerPage: k))
            for page in generator.pages {
                let count = Double(page.strokes.count)
                #expect(count >= 0.85 * Double(k) - 1 && count <= 1.15 * Double(k) + 1, "k \(k): \(count)")
                #expect(page.rev == UInt64(page.strokes.count))
            }
        }
    }

    @Test func pagesAreIndependentOfPageCount() {
        let small = FixtureGenerator(FixtureSpec(pages: 2, seed: 1))
        let large = FixtureGenerator(FixtureSpec(pages: 5, seed: 1))
        let a = small.page(at: 1)
        let b = large.page(at: 1)
        #expect(a.template == b.template)
        #expect(a.strokes.map(\.samples) == b.strokes.map(\.samples), "page i has the same ink in every fixture of a seed")
        #expect(a.id != b.id && small.notebook.id != large.notebook.id, "but never shares IDs")
        #expect(large.notebook.pages == large.notebook.pages.sorted(), "page IDs time-ordered")
    }

    @Test func templatesAndPaperVary() {
        let generator = FixtureGenerator(FixtureSpec(pages: 30, seed: 2, strokesPerPage: 0))
        let templates = Set(generator.pages.map(\.template))
        #expect(templates.count >= 3)
        #expect(templates.contains(generator.notebook.paper.defaultTemplate))
        let papers = Set((1 ... 30).map { FixtureGenerator(FixtureSpec(pages: 1, seed: $0)).notebook.paper })
        #expect(papers.count >= 3)
        #expect(FixtureGenerator(FixtureSpec(pages: 1, paper: .cornell)).notebook.paper == .cornell)
    }

    @Test func emptyPagesWriteNoStrokeFiles() async throws {
        try await withTemporaryDirectory { dir in
            let url = dir.appending(path: "e.nb")
            let report = try FixtureGenerator(FixtureSpec(pages: 3, seed: 1, strokesPerPage: 0)).write(to: url)
            #expect(report.strokes == 0)
            #expect(try FileManager.default.contentsOfDirectory(atPath: report.package.pagesDirectory.path(percentEncoded: false)).isEmpty)
            #expect(try NotebookPackage.open(at: url).manifest.pages.count == 3)
        }
    }
}
