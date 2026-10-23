import Export
import Foundation
import InkModel
import Testing

private let isReleaseBuild: Bool = {
    #if DEBUG
        false
    #else
        true
    #endif
}()

/// Budget (§9): 100 pages × 400 strokes (~60 samples each) < 3 s, output < 10 MB.
/// Run with `swift test -c release --filter PerformanceTests`; prints time and size to stderr. Debug builds
/// export 2 pages and only report.
struct PerformanceTests {
    @Test func export100DensePages() async throws {
        let pageCount = isReleaseBuild ? 100 : 2
        var rng = SplitMix64(state: 100)
        let pages = (0 ..< pageCount).map { _ in Fixtures.densePage(&rng, strokes: 400) }
        let exporter = PDFExporter(palette: TestPalette())

        let clock = ContinuousClock()
        var url: URL?
        let elapsed = try await clock.measure {
            url = try await exporter.exportPDF(pages: pages, options: PDFExportOptions(title: "Perf"))
        }
        let file = try #require(url)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bytes = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let line = String(
            format: "export %d pages × 400 strokes: %.2f s, %.2f MB (%@, %d cores)\n",
            pageCount,
            seconds,
            Double(bytes) / 1e6,
            isReleaseBuild ? "release" : "debug",
            ProcessInfo.processInfo.activeProcessorCount
        )
        FileHandle.standardError.write(Data(line.utf8))

        #expect(try PDF(Data(contentsOf: file)).pageCount == pageCount)
        if isReleaseBuild {
            #expect(seconds < 3, "\(seconds) s")
            #expect(bytes < 10_000_000, "\(bytes) bytes")
        }
    }
}
