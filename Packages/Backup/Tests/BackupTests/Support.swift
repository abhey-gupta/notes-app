@testable import Backup
import Document
import Foundation
import InkModel
import Library
import Testing

/// A throwaway library (app-container layout) and backup folder; removed on deinit.
final class TempBackup: Sendable {
    let root: URL
    let locations: LibraryLocations
    let folder: URL
    let store: LibraryStore

    init(folder: URL? = nil) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "BackupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.folder = folder ?? root.appending(path: "Backup Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        locations = LibraryLocations(root: root.appending(path: "Container", directoryHint: .isDirectory))
        store = LibraryStore(locations: locations)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func engine(device: String = "Test iPad") -> BackupEngine {
        BackupEngine(folder: .url(folder), library: store, device: device)
    }

    func remote(_ relative: String) -> URL {
        folder.appending(path: relative)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func package(_ entry: LibraryEntry) throws -> NotebookPackage {
        try NotebookPackage.open(at: locations.packageURL(for: entry))
    }

    /// Adds a stroke to the page at `index` and checkpoints it (page and notebook `rev` move).
    func ink(_ entry: LibraryEntry, page index: Int, images: [PageImage] = []) throws {
        var package = try package(entry)
        let page = try package.loadPage(at: index)
        let stroke = Stroke(
            tool: .ballpoint, color: .primary, width: 2,
            samples: (0 ..< 8).map { Sample(x: Float($0) * 10, y: Float(page.strokes.count) * 5) }
        )
        try package.savePage(Page(
            id: page.id,
            template: page.template,
            strokes: page.strokes + [stroke],
            images: page.images + images,
            rev: page.rev + 1
        ))
    }

    func catalog() throws -> BackupCatalog {
        try #require(BackupCatalog.decode(Data(contentsOf: remote("library.json"))))
    }

    /// Package-relative paths written by a run, per notebook group.
    func relative(_ written: [[URL]]) -> [Set<String>] {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return written.map { Set($0.map { String($0.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix.count)) }) }
    }
}

func notebook(_ title: String, pages: Int = 1, modified: Date = Date()) -> Notebook {
    Notebook(
        title: title,
        cover: .navy,
        paper: .dotted,
        pages: (0 ..< pages).map { _ in PageID() },
        createdAt: modified,
        modifiedAt: modified
    )
}
