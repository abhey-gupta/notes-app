import Document
import Foundation
import InkModel
import Library
import os

/// Two-way sync of the library through a folder the user picked (#225). One actor, so passes never overlap.
///
/// - **Push**: scan the library against the state's local markers (``LocalScan``) → ops with fresh clocks →
///   copy their blobs into the folder → one `log/<me>/<seq>.json` → `devices/<me>.json`. Blobs land before
///   the entry that names them, so a reader never sees an op without its files on the writer's side.
/// - **Pull**: list `log/*/`, read entries past the seq applied per device (a gap stops that device until
///   the next pass), merge their ops in stamp order (``Apply``), then write what changed into the library:
///   folders, notebook packages (strokes copied out of the folder, journals and page thumbnails of
///   replaced pages dropped, `manifest.json` rewritten with its `rev` bumped), trash, deletes. A notebook
///   whose blobs haven't downloaded yet keeps its previous version and is retried next pass; one open in an
///   editor is deferred until ``applyDeferred(_:)``. Then `devices/<me>.json` records the acks.
///
/// Everything after the library snapshot is synchronous file I/O on this actor, never on main.
public actor SyncEngine {
    /// Unreferenced blobs and acked log entries are deleted this long after they stop being needed.
    public static let gcDelay: TimeInterval = 30 * 86400
    /// Devices unseen this long no longer hold up GC.
    public static let activeWindow: TimeInterval = 90 * 86400
    /// `devices/<me>.json` is rewritten at least this often while syncing ("last seen").
    static let lastSeenInterval: TimeInterval = 3600

    public nonisolated let folder: SyncFolder
    public nonisolated let device: DeviceIdentity
    let fs: any SyncFileSystem
    nonisolated let library: LibraryStore
    let stateURL: URL
    let now: @Sendable () -> Date
    private let bookmarkRefreshed: @Sendable (Data) -> Void
    var openNotebooks: Set<NotebookID> = []
    private var cached: SyncState?
    var lastDeviceRecord: DeviceRecord?
    static let log = Logger(subsystem: "com.abhey.notespace", category: "sync")

    /// - Parameters:
    ///   - fileSystem: The folder's files (``CoordinatedFileSystem`` over `folder`'s URL in the app).
    ///   - stateURL: `Application Support/Library/sync-state.json` (``SyncState``).
    ///   - bookmarkRefreshed: A stale bookmark was renewed; store the new one.
    public init(
        folder: SyncFolder,
        fileSystem: any SyncFileSystem,
        library: LibraryStore,
        device: DeviceIdentity,
        stateURL: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        bookmarkRefreshed: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.folder = folder
        fs = fileSystem
        self.library = library
        self.device = device
        self.stateURL = stateURL
        self.now = now
        self.bookmarkRefreshed = bookmarkRefreshed
    }

    // MARK: Passes

    /// Pull, then push.
    @discardableResult
    public func sync(progress: @Sendable (SyncProgress) -> Void = { _ in }) async throws(SyncError) -> (PullReport, PushReport) {
        let pulled = try await pull(progress: progress)
        let pushed = try await push(progress: progress)
        return (pulled, pushed)
    }

    /// Reads other devices' new log entries and writes what they changed into the library.
    /// - Parameter progress: Called (on this actor) before each notebook it writes.
    @discardableResult
    public func pull(progress: @Sendable (SyncProgress) -> Void = { _ in }) async throws(SyncError) -> PullReport {
        try await withState { state throws(SyncError) in
            var report = PullReport()
            let isSyncFolder = try readFormat() != nil
            if isSyncFolder {
                try merge(readLogs(after: state.applied), into: &state)
            }
            try await materialise(&state, report: &report, progress: progress)
            if isSyncFolder {
                try writeDevice(state)
            }
            return report
        }
    }

    /// Fresh device with a folder: everything in it comes into the (empty) library ("Bringing in N notebooks").
    @discardableResult
    public func adoptAll(progress: @Sendable (SyncProgress) -> Void = { _ in }) async throws(SyncError) -> PullReport {
        try await pull(progress: progress)
    }

    /// Sends what changed in the library since the last push.
    /// - Parameter progress: Called (on this actor) before each notebook with files to copy.
    @discardableResult
    public func push(progress: @Sendable (SyncProgress) -> Void = { _ in }) async throws(SyncError) -> PushReport {
        let snapshot = await library.snapshot()
        let locations = library.locations
        return try await withState { state throws(SyncError) in
            let date = now()
            var next = state
            let (ops, scanned) = Self.scan(snapshot, locations: locations, state: &next, now: date)
            var report = PushReport()
            if !ops.isEmpty {
                for (local, changes) in scanned where !changes.uploads.isEmpty {
                    progress(SyncProgress(
                        direction: .sending, notebook: local.entry.title, device: nil, done: report.pages, total: changes.pages
                    ))
                    for upload in changes.uploads {
                        try fs.copyIn(upload.local, to: upload.path)
                        report.written.append(fs.url(upload.path))
                        report.bytes += upload.bytes
                    }
                    report.pages += changes.pages
                }
                report.notebooks = Set(ops.compactMap(\.change.notebook)).count
                try report.written.append(append(ops, to: &next))
            }
            for (local, changes) in scanned {
                Self.recordSent(changes, of: local, device: device.id, in: &next)
            }
            for op in ops {
                if case let .lifecycle(id, .delete) = op.change {
                    next.notebooks[id]?.materialised = false
                }
            }
            Self.recordSent(folders: snapshot.folders, in: &next)
            state = next
            if !ops.isEmpty {
                try writeDevice(state, force: true)
                Self.log.info("sync: pushed \(ops.count) ops, \(report.pages) pages")
            }
            return report
        }
    }

    // MARK: Editors and conflicts

    /// Notebooks open in an editor: incoming page changes for them wait for ``applyDeferred(_:)``.
    public func setOpenNotebooks(_ ids: Set<NotebookID>) {
        openNotebooks = ids
    }

    /// Writes a deferred notebook's merged changes now that its editor closed.
    @discardableResult
    public func applyDeferred(_ id: NotebookID) async throws(SyncError) -> PullReport {
        openNotebooks.remove(id)
        return try await withState { state throws(SyncError) in
            state.deferred.remove(id)
            var report = PullReport()
            try await materialise(&state, report: &report, only: id, progress: { _ in })
            return report
        }
    }

    /// Pages whose ink was replaced by another device's version.
    public func conflicts() async throws(SyncError) -> [Conflict] {
        try await withState { state throws(SyncError) in state.conflicts }
    }

    /// Keep mine: sends the replaced version again as a new `pageSet` (a fresh clock, so it wins everywhere)
    /// and writes it back into the page (deferred while the notebook is open).
    public func keepMine(notebook: NotebookID, page: PageID) async throws(SyncError) {
        try await withState { state throws(SyncError) in
            guard let conflict = state.conflicts.first(where: { $0.notebook == notebook && $0.page == page }),
                  let current = state.notebooks[notebook]?.pages[page] else { return }
            let op = SyncOp(
                clock: state.tick(), at: now(),
                .pageSet(notebook, page: page, base: current.stamp.clock, entry: current.meta, strokes: conflict.mine)
            )
            _ = try append([op], to: &state)
            state.conflicts.removeAll { $0.notebook == notebook && $0.page == page }
            try writeDevice(state, force: true)
            var report = PullReport()
            try await materialise(&state, report: &report, only: notebook, progress: { _ in })
        }
    }

    /// Lets the replaced version go (the pill's ×, or its 30 s).
    public func dismissConflict(notebook: NotebookID, page: PageID) async throws(SyncError) {
        try await withState { state throws(SyncError) in
            for conflict in state.conflicts where conflict.notebook == notebook && conflict.page == page {
                letGo(conflict, in: &state)
            }
            state.conflicts.removeAll { $0.notebook == notebook && $0.page == page }
        }
    }

    /// A conflict's `mine` blob, if this device wrote it, becomes garbage (GC keeps it while still referenced).
    func letGo(_ conflict: Conflict, in state: inout SyncState) {
        guard SyncLayout.device(ofBlob: conflict.mine) == device.id else { return }
        let path = SyncLayout.strokes(conflict.mine, notebook: conflict.notebook, page: conflict.page)
        state.garbage[path] = state.garbage[path] ?? Garbage(since: now(), acks: [:])
    }

    /// Every device syncing through the folder, this one first, then most recently seen.
    public func devices() throws(SyncError) -> [DeviceRecord] {
        let scope = try folder.beginAccess(refreshed: bookmarkRefreshed)
        defer { scope.end() }
        return try readDevices().sorted { a, b in
            a.id == device.id || (b.id != device.id && a.lastSeen > b.lastSeen)
        }
    }

    // MARK: State

    /// Runs `body` on the state inside the folder's scope, saving it afterwards (also when `body` throws:
    /// whatever it recorded is consistent, and the rest is retried next pass).
    func withState<T>(_ body: (inout SyncState) async throws(SyncError) -> T) async throws(SyncError) -> T {
        let scope = try folder.beginAccess(refreshed: bookmarkRefreshed)
        defer { scope.end() }
        let root = scope.url.path(percentEncoded: false)
        var state = cached.flatMap { $0.folder == root ? $0 : nil }
            ?? SyncState.load(from: stateURL, folder: root, deviceId: device.id)
        do {
            let result = try await body(&state)
            cached = state
            try state.save(to: stateURL)
            return result
        } catch {
            cached = state
            try? state.save(to: stateURL)
            throw error
        }
    }
}

/// Where a pass is, for the library's title line ("Sending Physics · 3 pages", "Updating from iPhone · 2 of 5
/// pages") and the adopt card.
public struct SyncProgress: Hashable, Sendable {
    public enum Direction: Hashable, Sendable {
        case sending
        case receiving
    }

    public var direction: Direction
    /// The notebook's title.
    public var notebook: String
    /// Receiving: the device the changes came from.
    public var device: String?
    /// Pages done before this notebook, and the pass's total (sending: this notebook's pages).
    public var done: Int
    public var total: Int
}

/// What a pull wrote into the library.
public struct PullReport: Hashable, Sendable {
    /// Notebooks written (created, updated, trashed, deleted).
    public var applied: [NotebookID] = []
    /// Notebooks with changes waiting for their editor to close.
    public var deferred: [NotebookID] = []
    /// Notebooks waiting for blobs to download (retried next pass).
    public var waiting: [NotebookID] = []
    /// Pages whose ink was replaced in this pass.
    public var conflicts: [Conflict] = []
    /// Names of the devices the written changes came from.
    public var fromDevices: [String] = []

    public init() {}
}

/// What a push sent.
public struct PushReport: Hashable, Sendable {
    public var notebooks = 0
    public var pages = 0
    public var bytes: Int64 = 0
    /// Files written into the folder, for upload tracking.
    public var written: [URL] = []

    public init() {}
}
