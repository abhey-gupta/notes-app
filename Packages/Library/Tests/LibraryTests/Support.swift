import Foundation
import InkModel
@testable import Library

/// A throwaway app-container layout; removed on deinit.
final class TempLibrary: Sendable {
    let root: URL
    let locations: LibraryLocations

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "LibraryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        locations = LibraryLocations(root: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func store(now: @escaping @Sendable () -> Date = { Date() }) -> LibraryStore {
        LibraryStore(locations: locations, now: now)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }
}

func notebook(_ title: String, cover: CoverColor = .sage, pages: Int = 1, modified: Date = Date()) -> Notebook {
    Notebook(
        title: title, cover: cover, paper: .dotted, theme: .cream, pages: (0 ..< pages).map { _ in PageID() },
        createdAt: modified, modifiedAt: modified
    )
}

/// Median and best of `rounds` timings of `body`, in milliseconds.
func measureMilliseconds(rounds: Int, _ body: () throws -> Void) rethrows -> (median: Double, best: Double) {
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0 ..< rounds {
        let elapsed = try clock.measure(body)
        times.append(Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15)
    }
    times.sort()
    return (times[times.count / 2], times[0])
}

let isReleaseBuild: Bool = {
    #if DEBUG
        false
    #else
        true
    #endif
}()

func report(_ line: String) {
    FileHandle.standardError.write(Data("\(line) (\(isReleaseBuild ? "release" : "debug"))\n".utf8))
}
