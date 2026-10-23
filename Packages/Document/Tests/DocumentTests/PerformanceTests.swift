@testable import Document
import Foundation
import InkModel
import Testing

/// Budgets (release, warm file cache): decode a 400-stroke × 60-sample page < 5 ms; open a 100-page
/// notebook (manifest + page 1) < 20 ms. Run `swift test -c release --filter PerformanceTests`;
/// medians print to stderr. Debug builds only report.
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
}
