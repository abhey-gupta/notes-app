import Document
import FixtureGen
import Foundation
import InkModel
import Library

/// On-disk libraries for perf tests, built in the test runner with `FixtureGen` (ARCHITECTURE.md §12) and
/// handed to the app with `-libraryRoot <path>` (honored in DEBUG and simulator builds only).
///
/// Layout matches the app container (`Documents/Notebooks`, `Application Support/Library/index.json`).
/// Built once per simulator and reused: a `.complete` marker carries `version`; bump it when the
/// composition changes. Contents: the 1/10/100-page fixtures (seed 1, newest, so the 100-page one leads
/// "Continue") plus blank one-page filler notebooks with fixed, older dates up to `notebooks`.
struct PerfLibrary {
    static let version = "1"
    static let fixturePages = [1, 10, 100]

    let notebooks: Int
    let root: URL

    init(notebooks: Int) {
        self.notebooks = notebooks
        root = URL.cachesDirectory.appending(path: "PerfLibraries/\(notebooks)", directoryHint: .isDirectory)
    }

    /// Accessibility identifier of the 100-page fixture's library cover.
    static var largeFixtureCover: String {
        "cover-\(FixtureGenerator(FixtureSpec(pages: 100)).notebook.title)"
    }

    /// App launch arguments that point it at this library.
    var launchArguments: [String] {
        ["-libraryRoot", root.path(percentEncoded: false)]
    }

    /// Builds the library unless an up-to-date one is already there.
    func prepare() throws {
        let fm = FileManager.default
        let marker = root.appending(path: ".complete")
        if (try? String(contentsOf: marker, encoding: .utf8)) == Self.version {
            return
        }
        try? fm.removeItem(at: root)
        let locations = LibraryLocations(root: root)
        try fm.createDirectory(at: locations.notebooksDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: locations.libraryDirectory, withIntermediateDirectories: true)

        var entries: [LibraryEntry] = []
        for pages in Self.fixturePages {
            let generator = FixtureGenerator(FixtureSpec(pages: pages))
            let url = NotebookPackage.url(for: generator.notebook.id, in: locations.notebooksDirectory)
            let report = try generator.write(to: url)
            entries.append(LibraryEntry(manifest: report.package.manifest, packagePath: url.lastPathComponent))
        }
        let newest = Date(timeIntervalSince1970: 1_766_000_000) // 2025-12-17, before every fixture
        for i in 0 ..< max(0, notebooks - entries.count) {
            let date = newest.addingTimeInterval(-Double(i) * 3600)
            let notebook = Notebook(
                title: String(format: "Notebook %04d", i + 1),
                cover: CoverColor.allCases[i % CoverColor.allCases.count],
                paper: PaperStyle.allCases[i % PaperStyle.allCases.count],
                theme: PaperTheme.allCases[i % PaperTheme.allCases.count],
                createdAt: date,
                modifiedAt: date
            )
            let url = NotebookPackage.url(for: notebook.id, in: locations.notebooksDirectory)
            let package = try NotebookPackage.create(at: url, notebook: notebook)
            entries.append(LibraryEntry(manifest: package.manifest, packagePath: url.lastPathComponent))
        }
        try LibraryIndex(notebooks: entries).encoded().write(to: locations.indexURL, options: .atomic)
        try Self.version.write(to: marker, atomically: true, encoding: .utf8)
    }
}
