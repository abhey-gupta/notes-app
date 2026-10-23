@testable import Document
import Foundation
import InkModel

func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
}

/// Fresh package with `pages` empty pages, in a temp dir removed afterwards.
func withPackage<R>(pages: Int = 2, _ body: (NotebookPackage) async throws -> R) async throws -> R {
    let dir = FileManager.default.temporaryDirectory.appending(path: "DocumentStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let notebook = Notebook(title: "Store", paper: .lined, pages: (0 ..< pages).map { _ in PageID() })
    let package = try NotebookPackage.create(at: dir.appending(path: "n.nb"), notebook: notebook)
    return try await body(package)
}

/// A store that never checkpoints by itself, so tests decide when (or whether) it happens.
func manualStore(_ url: URL, journalLimit: Int = 1 << 20) throws -> DocumentStore {
    try DocumentStore(opening: url, options: .init(idleDelay: nil, journalLimit: journalLimit))
}

/// Opens a store, runs `body`, then drops the store without flushing: the in-process equivalent of a
/// kill. Every append was already written + synced; nothing else happens on drop (no idle task).
@discardableResult
func session<R>(_ url: URL, _ body: (DocumentStore) async throws -> R) async throws -> R {
    try await body(manualStore(url))
}

func addEdit(_ store: DocumentStore, _ id: PageID, _ rng: inout SplitMix64, samples: Int = 20) async throws -> PageEdit {
    try await store.page(id).addEdit([Fixtures.stroke(&rng, samples: samples)])
}

/// Stroke with integer sample coordinates, so translations undo exactly.
func gridStroke(_ i: Int) -> Stroke {
    Stroke(
        tool: .ballpoint, color: .primary, width: 2,
        samples: (0 ..< 10).map { Sample(x: Float(i * 10 + $0), y: Float(i * 7), t: Float($0) / 240) }
    )
}
