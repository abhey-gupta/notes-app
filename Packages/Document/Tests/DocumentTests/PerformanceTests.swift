@testable import Document
import Foundation
import InkModel
import Testing

/// Budgets (release, warm file cache): decode a 400-stroke × 60-sample page < 5 ms; open a 100-page
/// notebook (manifest + page 1) < 20 ms; pen-up → durable (``DocumentStore/apply(_:to:)`` of one
/// 120-sample stroke, journal synced) p95 < 50 ms; checkpoint of 100 dirty pages < 500 ms.
/// Run `swift test -c release --filter PerformanceTests`; numbers print to stderr. Debug builds only report.
@Suite(.serialized)
struct PerformanceTests {
    @Test func decodeDensePage() throws {
        let strokes = Fixtures.densePage()
        let data = try StrokeCodec.encode(strokes)
        var decoded: [Stroke] = []
        let decode = try measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) { decoded = try StrokeCodec.decode(data) }
        let encode = try measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) { _ = try StrokeCodec.encode(strokes) }
        #expect(decoded == strokes)
        report(String(
            format: "page 400×60 (%d B lz4): decode median %.3f ms (best %.3f), encode median %.3f ms (best %.3f)",
            data.count, decode.median, decode.best, encode.median, encode.best
        ))
        if isReleaseBuild {
            #expect(decode.median < 5, "decode median \(decode.median) ms")
        }
    }

    @Test func openHundredPageNotebook() throws {
        try withTemporaryDirectory { dir in
            let strokes = Fixtures.densePage()
            let notebook = Notebook(title: "Fixture 100", paper: .lined, pages: (0 ..< 100).map { _ in PageID() })
            var package = try NotebookPackage.create(at: dir.appending(path: "f.nb"), notebook: notebook)
            try package.savePages(notebook.pages.map { Page(id: $0, template: .lined(spacing: 24), strokes: strokes, rev: 1) })

            var first: Page?
            let open = try measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) {
                let opened = try NotebookPackage.open(at: package.url)
                first = try opened.loadPage(at: 0)
            }
            let manifestOnly = try measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) {
                _ = try NotebookPackage.open(at: package.url)
            }
            #expect(first?.strokes.count == 400)
            report(String(
                format: "100-page notebook: manifest + page 1 median %.3f ms (best %.3f); manifest alone median %.3f ms",
                open.median, open.best, manifestOnly.median
            ))
            if isReleaseBuild {
                #expect(open.median < 20, "open median \(open.median) ms")
            }
        }
    }

    @Test func appendLatency() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DocumentPerf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let notebook = Notebook(title: "Append", pages: [PageID()])
        let id = notebook.pages[0]
        var package = try NotebookPackage.create(at: dir.appending(path: "a.nb"), notebook: notebook)
        try package.savePage(Page(id: id, strokes: Fixtures.densePage()))

        let store = try DocumentStore(opening: package.url, options: .init(idleDelay: nil))
        var rng = SplitMix64(seed: 99)
        _ = try await store.page(id)
        let count = isReleaseBuild ? 500 : 40
        let clock = ContinuousClock()
        var times: [Double] = []
        for _ in 0 ..< count {
            // A typical handwriting stroke: ~0.5 s at 240 Hz.
            let stroke = Fixtures.stroke(&rng, samples: 120)
            let edit = try await store.page(id).addEdit([stroke])
            let elapsed = try await clock.measure { try await store.apply(edit, to: id) }
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3)
        }
        let first = times[0]
        let sorted = times.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)]
        }
        report(String(
            format: "apply 120-sample stroke → durable (n=%d): p50 %.3f ms, p95 %.3f ms, max %.3f ms, first (creates .wal) %.3f ms",
            count, percentile(0.5), percentile(0.95), sorted[sorted.count - 1], first
        ))
        if isReleaseBuild {
            #expect(percentile(0.95) < 50, "p95 \(percentile(0.95)) ms")
        }
    }

    @Test func checkpointHundredDirtyPages() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DocumentPerf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let strokes = Fixtures.densePage()
        let notebook = Notebook(title: "Checkpoint", pages: (0 ..< 100).map { _ in PageID() })
        var package = try NotebookPackage.create(at: dir.appending(path: "c.nb"), notebook: notebook)
        try package.savePages(notebook.pages.map { Page(id: $0, strokes: strokes) })

        let store = try DocumentStore(opening: package.url, options: .init(idleDelay: nil))
        var rng = SplitMix64(seed: 98)
        for id in notebook.pages {
            try await store.apply(store.page(id).addEdit([Fixtures.stroke(&rng, samples: 120)]), to: id)
        }
        let elapsed = try await ContinuousClock().measure { try await store.flush() }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
        report(String(format: "checkpoint 100 dirty pages (401 strokes × 60 samples each, ~58 MB): %.1f ms", ms))
        if isReleaseBuild {
            #expect(ms < 500, "checkpoint \(ms) ms")
        }
    }
}
