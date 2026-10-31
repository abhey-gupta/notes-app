import Dispatch
import Document
import Foundation
import InkModel
import Library
@testable import Sync
import Synchronization
import Testing

/// The real folder (``CoordinatedFileSystem`` over a temp directory) as one device sees it, with faults:
/// files that arrive late (``delay(_:lists:)``, ``hold(_:)``), evicted files that download only after
/// ``SyncFileSystem/startDownload(_:)`` and a later listing, listings missing names (``dropOnce(_:)``), a copy
/// out of the folder that stalls mid-pull (``stallCopyOut(_:)``). Records every path written.
final class FaultyFileSystem: SyncFileSystem {
    private struct Faults {
        /// Path prefix → visible from this many `list` calls on.
        var delays: [String: Int] = [:]
        var evicted: [String] = []
        var downloading: Set<String> = []
        var downloaded: Set<String> = []
        var dropped: Set<String> = []
        var lists = 0
        var writes: [String] = []
        var downloadRequests: [String] = []
        var stalled: String?
        var stalling = false
    }

    let inner: CoordinatedFileSystem
    private let faults = Mutex(Faults())
    private let stallRelease = DispatchSemaphore(value: 0)

    init(root: URL) {
        inner = CoordinatedFileSystem(root: root, timeout: .seconds(10))
    }

    /// Paths under `prefix` are missing for the next `lists` listings.
    func delay(_ prefix: String, lists: Int) {
        faults.withLock { $0.delays[prefix] = $0.lists + lists }
    }

    /// Paths under `prefix` are missing until ``release(_:)``.
    func hold(_ prefix: String) {
        faults.withLock { $0.delays[prefix] = .max }
    }

    func release(_ prefix: String) {
        faults.withLock { $0.delays[prefix] = nil }
    }

    /// Paths under `prefix` are placeholders until downloaded.
    func evict(_ prefix: String) {
        faults.withLock { $0.evicted.append(prefix) }
    }

    /// The next listing that has `name` leaves it out.
    func dropOnce(_ name: String) {
        _ = faults.withLock { $0.dropped.insert(name) }
    }

    /// The next copy out of a path under `prefix` blocks (the engine's thread with it) until ``releaseStall()``.
    func stallCopyOut(_ prefix: String) {
        faults.withLock { $0.stalled = prefix }
    }

    /// A stalled copy has started.
    var isStalling: Bool {
        faults.withLock { $0.stalling }
    }

    func releaseStall() {
        stallRelease.signal()
    }

    var writes: [String] {
        faults.withLock { $0.writes }
    }

    var downloadRequests: [String] {
        faults.withLock { $0.downloadRequests }
    }

    func clearWrites() {
        faults.withLock { $0.writes = [] }
    }

    private func hidden(_ path: String) -> Bool {
        faults.withLock { f in f.delays.contains { path.hasPrefix($0.key) && f.lists <= $0.value } }
    }

    private func evicted(_ path: String) -> Bool {
        faults.withLock { f in f.evicted.contains { path.hasPrefix($0) } && !f.downloaded.contains(path) }
    }

    func url(_ path: String) -> URL {
        inner.url(path)
    }

    func list(_ directory: String) throws(SyncError) -> [String] {
        let names = try inner.list(directory)
        return faults.withLock { f in
            f.lists += 1
            f.downloaded.formUnion(f.downloading)
            f.downloading = []
            return names.filter { name in
                let path = "\(directory)/\(name)"
                if f.dropped.remove(name) != nil {
                    return false
                }
                return !f.delays.contains { path.hasPrefix($0.key) && f.lists <= $0.value }
            }
        }
    }

    func read(_ path: String) throws(SyncError) -> Data? {
        guard !hidden(path), !evicted(path) else { return nil }
        return try inner.read(path)
    }

    func write(_ path: String, _ data: Data) throws(SyncError) {
        try inner.write(path, data)
        faults.withLock { $0.writes.append(path) }
    }

    func copyIn(_ local: URL, to path: String) throws(SyncError) {
        try inner.copyIn(local, to: path)
        faults.withLock { $0.writes.append(path) }
    }

    func copyOut(_ path: String, to local: URL) throws(SyncError) {
        guard !hidden(path), !evicted(path) else { throw .failed("not downloaded: \(path)") }
        let stalls = faults.withLock { f in
            guard let prefix = f.stalled, path.hasPrefix(prefix) else { return false }
            f.stalled = nil
            f.stalling = true
            return true
        }
        if stalls {
            stallRelease.wait()
        }
        try inner.copyOut(path, to: local)
    }

    func delete(_ path: String) throws(SyncError) {
        try inner.delete(path)
    }

    func isDownloaded(_ path: String) -> Bool {
        !hidden(path) && !evicted(path) && inner.isDownloaded(path)
    }

    func startDownload(_ path: String) {
        faults.withLock {
            $0.downloadRequests.append(path)
            if $0.evicted.contains(where: { path.hasPrefix($0) }) {
                $0.downloading.insert(path)
            }
        }
    }
}

/// A settable clock shared by a test's devices.
final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.date = Mutex(date)
    }

    var now: Date {
        date.withLock { $0 }
    }

    func advance(days: Double) {
        date.withLock { $0 += days * 86400 }
    }
}

/// A throwaway sync folder, removed on deinit.
final class TempFolder: Sendable {
    let root: URL
    let clock = TestClock()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "SyncTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: path).path(percentEncoded: false))
    }

    /// Relative paths of every file under `directory`.
    func files(under directory: String) -> Set<String> {
        let base = root.appending(path: directory)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var files: Set<String> = []
        let prefix = root.standardizedFileURL.path(percentEncoded: false)
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files
                .insert(String(url.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix.count)).trimmingPrefix("/").description)
        }
        return files
    }
}

/// One device: its own library (app-container layout) and engine on the shared folder.
final class Device: Sendable {
    let name: String
    let id: String
    let root: URL
    let locations: LibraryLocations
    let store: LibraryStore
    let fs: FaultyFileSystem
    let folder: TempFolder
    private let current: Mutex<SyncEngine>

    init(_ name: String, folder: TempFolder) {
        self.name = name
        self.folder = folder
        id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appending(path: "SyncTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        locations = LibraryLocations(root: root)
        store = LibraryStore(locations: locations)
        fs = FaultyFileSystem(root: folder.root)
        current = Mutex(Self.makeEngine(DeviceIdentity(id: id, name: name, model: "iPad"), folder: folder, store: store, fs: fs))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private static func makeEngine(_ device: DeviceIdentity, folder: TempFolder, store: LibraryStore, fs: FaultyFileSystem) -> SyncEngine {
        let clock = folder.clock
        return SyncEngine(
            folder: .url(folder.root), fileSystem: fs, library: store, device: device,
            stateURL: store.locations.libraryDirectory.appending(path: SyncState.fileName), now: { clock.now }
        )
    }

    var engine: SyncEngine {
        current.withLock { $0 }
    }

    var stateURL: URL {
        locations.libraryDirectory.appending(path: SyncState.fileName)
    }

    /// A new engine (as after a relaunch): drops the cached state.
    func relaunch() {
        current.withLock { $0 = Self.makeEngine(DeviceIdentity(id: id, name: name, model: "iPad"), folder: folder, store: store, fs: fs) }
    }

    @discardableResult
    func sync() async throws -> (PullReport, PushReport) {
        try await engine.sync()
    }

    func package(_ id: NotebookID) async throws -> NotebookPackage {
        let entry = try #require(await store.snapshot().notebook(id))
        return try NotebookPackage.open(at: locations.packageURL(for: entry))
    }

    /// Adds a stroke to the page at `index` and checkpoints it, then tells the library (as the editor does).
    func ink(_ id: NotebookID, page index: Int) async throws {
        var package = try await package(id)
        let page = try package.loadPage(at: index)
        let stroke = Stroke(
            tool: .ballpoint, color: .primary, width: 2,
            samples: (0 ..< 8).map { Sample(x: Float($0) * 10, y: Float(page.strokes.count) * 5 + Float(name.count)) }
        )
        try package.savePage(Page(
            id: page.id,
            template: page.template,
            strokes: page.strokes + [stroke],
            images: page.images,
            rev: page.rev + 1
        ))
        try await store.refresh(id)
    }

    /// Writes the stroke file `data` into the page at `index` as an editor would (a checkpoint at the next
    /// `rev`), then tells the library. Returns the page's new `rev`.
    func write(_ data: Data, to id: NotebookID, page index: Int) async throws -> UInt64 {
        var package = try await package(id)
        let page = try package.loadPage(at: index)
        let content = try StrokeCodec.decodeContent(data)
        try package.savePage(Page(id: page.id, template: page.template, strokes: content.strokes, images: content.images, rev: page.rev + 1))
        try await store.refresh(id)
        return page.rev + 1
    }

    /// The stroke file of the page at `index` (nil: no ink).
    func strokes(_ id: NotebookID, page index: Int) async throws -> Data? {
        let package = try await package(id)
        return try? Data(contentsOf: package.strokesURL(for: package.manifest.notebook.pages[index]))
    }

    func pageIDs(_ id: NotebookID) async throws -> [PageID] {
        try await package(id).manifest.notebook.pages
    }
}

func notebook(_ title: String, pages: Int = 1) -> Notebook {
    Notebook(title: title, cover: .navy, paper: .dotted, pages: (0 ..< pages).map { _ in PageID() })
}

/// Relative folder paths of `urls`.
func relative(_ urls: [URL], to folder: TempFolder) -> Set<String> {
    let base = folder.root.standardizedFileURL.path(percentEncoded: false)
    let prefix = base.hasSuffix("/") ? base : base + "/"
    return Set(urls.map { String($0.standardizedFileURL.path(percentEncoded: false).dropFirst(prefix.count)) })
}

/// Two devices in sync on one notebook.
struct Pair {
    let folder: TempFolder
    let a: Device
    let b: Device
    let id: NotebookID
    let physics: FolderID

    /// A and B in sync on one inked two-page notebook in folder "Physics" (with a photo and a cover).
    static func make() async throws -> Pair {
        let folder = try TempFolder()
        let a = Device("A", folder: folder)
        let b = Device("B", folder: folder)
        let physics = try await a.store.createFolder(named: "Physics")
        let entry = try await a.store.create(notebook("Thermodynamics", pages: 2), in: physics.id)
        try await a.package(entry.id).writeImage(Data("photo".utf8), asset: ImageAssetID())
        try await a.ink(entry.id, page: 0)
        try await Data("cover".utf8).write(to: a.package(entry.id).coverThumbnailURL)
        try await a.sync()
        try await b.sync()
        return Pair(folder: folder, a: a, b: b, id: entry.id, physics: physics.id)
    }
}
