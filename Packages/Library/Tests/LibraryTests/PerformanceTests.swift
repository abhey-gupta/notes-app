import Foundation
import InkModel
@testable import Library
import Testing

/// Budget (release, M-series): decode a 1 000-notebook index < 5 ms (§8, #34). Run
/// `swift test -c release --package-path Packages/Library --filter PerformanceTests`; medians print to
/// stderr. Debug builds only report.
@Suite(.serialized)
struct PerformanceTests {
    @Test func decodeThousandEntryIndex() throws {
        let folders = (0 ..< 8).map { LibraryFolder(name: "Folder \($0)") }
        let notebooks = (0 ..< 1000).map { i in
            var e = entry(
                "Notebook \(i) – Lecture notes",
                folder: i % 3 == 0 ? nil : folders[i % 8].id,
                modified: 1_800_000_000 + Double(i)
            )
            e.coverThumbnailPath = i % 2 == 0 ? e.coverThumbnailPath : nil
            return e
        }
        let index = LibraryIndex(notebooks: notebooks, folders: folders)
        let data = try index.encoded()

        var decoded = LibraryIndex()
        let decode = try measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) { decoded = try LibraryIndex.decode(data) }
        let encode = try measureMilliseconds(rounds: isReleaseBuild ? 20 : 3) { _ = try index.encoded() }
        #expect(decoded == index)
        report(String(
            format: "1000-entry index (%d KB): decode median %.2f ms (best %.2f), encode median %.2f ms",
            data.count / 1024, decode.median, decode.best, encode.median
        ))
        if isReleaseBuild {
            #expect(decode.median < 5, "decode median \(decode.median) ms")
        }
    }

    @Test func launchReadThousandEntryIndex() throws {
        let lib = try TempLibrary()
        let notebooks = (0 ..< 1000).map { entry("Notebook \($0)", modified: 1_800_000_000 + Double($0)) }
        try FileManager.default.createDirectory(at: lib.locations.libraryDirectory, withIntermediateDirectories: true)
        try LibraryIndex(notebooks: notebooks).encoded().write(to: lib.locations.indexURL)

        var count = 0
        let read = measureMilliseconds(rounds: isReleaseBuild ? 50 : 5) {
            count = LibraryStore.readIndex(at: lib.locations)?.notebooks.count ?? 0
        }
        #expect(count == 1000)
        report(String(format: "1000-entry index: readIndex (file + decode) median %.2f ms (best %.2f)", read.median, read.best))
    }
}
