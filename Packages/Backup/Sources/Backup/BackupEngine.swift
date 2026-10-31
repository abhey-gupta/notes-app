import Document
import Foundation
import InkModel
import Library
import os

/// Backs the library up to a folder and restores from it (#174). One actor, so runs never overlap; the app
/// coalesces requests (a run asked for during one runs once after it).
///
/// A run: snapshot the library → `stat` every package → read the manifests that moved → plan
/// (``BackupPlanner``) → apply per notebook, recording ``BackupState`` as it goes → rewrite `library.json` if
/// its contents changed. Everything after the snapshot is synchronous file I/O on this actor, never on main.
public actor BackupEngine {
    /// Progress of a run with notebooks to copy.
    public struct Progress: Hashable, Sendable {
        /// The notebook being copied.
        public var title: String
        /// Notebooks finished.
        public var done: Int
        public var total: Int
        public var bytesLeft: Int64
    }

    /// What a run did.
    public struct Run: Sendable {
        /// Notebooks copied, moved or deleted (0: nothing to show).
        public var notebooks: Int
        /// Files written, one group per notebook (and one for `library.json`), for upload tracking.
        public var written: [[URL]]
        public var summary: BackupSummary
    }

    public nonisolated let folder: BackupFolder
    private nonisolated let library: LibraryStore
    private let device: String
    private let now: @Sendable () -> Date
    private let bookmarkRefreshed: @Sendable (Data) -> Void
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "backup")
    /// Saving the state after every notebook of a big first run would rewrite it thousands of times.
    private static let stateSaveInterval: TimeInterval = 2

    /// - Parameters:
    ///   - device: Shown on a fresh iPad's restore card ("Backed up from iPad").
    ///   - bookmarkRefreshed: A stale bookmark was renewed; store the new one.
    public init(
        folder: BackupFolder,
        library: LibraryStore,
        device: String,
        now: @escaping @Sendable () -> Date = { Date() },
        bookmarkRefreshed: @escaping @Sendable (Data) -> Void = { _ in }
    ) {
        self.folder = folder
        self.library = library
        self.device = device
        self.now = now
        self.bookmarkRefreshed = bookmarkRefreshed
    }

    nonisolated var stateURL: URL {
        library.locations.libraryDirectory.appending(path: BackupState.fileName, directoryHint: .notDirectory)
    }

    /// What the folder holds, from the state file (Settings' idle footer).
    public func summary() throws(BackupError) -> BackupSummary {
        let url = stateURL
        return try folder.access(refreshed: bookmarkRefreshed) { root in
            BackupSummary(BackupState.load(from: url, destination: root.path(percentEncoded: false)))
        }
    }

    /// Brings the folder up to date with the library.
    /// - Parameter progress: Called (on this actor) before each notebook that has files to copy.
    @discardableResult
    public func run(progress: @Sendable (Progress) -> Void = { _ in }) async throws(BackupError) -> Run {
        let snapshot = await library.snapshot()
        let (locations, stateURL, device, date) = (library.locations, stateURL, device, now)
        return try folder.access(refreshed: bookmarkRefreshed) { root in
            let destination = BackupDestination(root: root)
            var state = BackupState.load(from: stateURL, destination: root.path(percentEncoded: false))
            let listing = try destination.listing()
            var local = LocalScan.notebooks(in: snapshot, locations: locations)
            for i in local.indices where BackupPlanner.needsInspection(local[i], state: state, remote: listing) {
                LocalScan.inspect(&local[i])
            }
            let plans = BackupPlanner.plan(local: local, state: state, remote: listing)
            let work = plans.filter { !$0.operations.isEmpty }
            var bytesLeft = work.reduce(0) { $0 + $1.bytes }
            var written: [[URL]] = []
            var removed: Set<NotebookID> = []
            var saved = Date.distantPast
            defer { try? state.save(to: stateURL) }
            for plan in plans {
                if !plan.operations.isEmpty, plan.state != nil {
                    progress(Progress(title: plan.title, done: written.count, total: work.count, bytesLeft: bytesLeft))
                }
                let files = try Self.apply(plan, to: destination)
                if !plan.operations.isEmpty {
                    written.append(files)
                }
                bytesLeft -= plan.bytes
                state.notebooks[plan.id] = plan.state
                if plan.state == nil {
                    removed.insert(plan.id)
                }
                if Date().timeIntervalSince(saved) > Self.stateSaveInterval {
                    try? state.save(to: stateURL)
                    saved = Date()
                }
            }
            let remote = destination.readCatalog()
            let (folders, notebooks) = try BackupCatalog.merged(
                snapshot: snapshot, state: state, remote: remote, listing: destination.listing(), removed: removed
            )
            let catalog = BackupCatalog(folders: folders, notebooks: notebooks, device: device, writtenAt: date())
            if remote.map({ !catalog.hasContents(of: $0) }) ?? (!notebooks.isEmpty || !plans.isEmpty) {
                try destination.writeCatalog(catalog)
                written.append([destination.url(BackupLayout.catalog)])
            }
            state.lastBackup = date()
            Self.log.info("backup: \(work.count) notebooks copied, \(local.count) scanned")
            return Run(notebooks: work.count, written: written, summary: BackupSummary(state))
        }
    }

    /// Applies a notebook's operations in order; returns the files written.
    private static func apply(_ plan: NotebookPlan, to destination: BackupDestination) throws -> [URL] {
        var files: [URL] = []
        for operation in plan.operations {
            switch operation {
            case let .copy(source, to, _):
                try destination.copy(source, to: to)
                files.append(destination.url(to))
            case let .delete(path):
                try destination.delete(path)
            case let .move(path, to):
                try destination.move(path, to: to)
            }
        }
        return files
    }

    /// The folder's `library.json` (`nil`: none yet).
    public func catalog() throws(BackupError) -> BackupCatalog? {
        try folder.access(refreshed: bookmarkRefreshed) { BackupDestination(root: $0).readCatalog() }
    }

    /// How many of `written`'s groups still have files uploading (iCloud Drive; 0 for other providers).
    public func pendingUploads(_ written: [[URL]]) -> Int {
        (try? folder.access { _ in written.count { !BackupDestination.isUploaded($0) } }) ?? 0
    }

    /// Brings one backed-up notebook back into the library with its folders (``LibraryStore/adoptPackage(at:in:folders:)``)
    /// and records it as backed up, so the next run leaves it alone (a deleted one is moved out of `Trash/`).
    /// - Returns: `false` if the library already has it (it is never replaced).
    @discardableResult
    public func restore(_ item: BackupCatalog.Notebook, from catalog: BackupCatalog) async throws(BackupError) -> Bool {
        let snapshot = await library.snapshot()
        guard snapshot.notebook(item.id) == nil, !snapshot.trash.contains(where: { $0.id == item.id }) else { return false }
        let notebooks = library.locations.notebooksDirectory
        let staging = notebooks.appending(path: ".restore-\(UUID().uuidString)", directoryHint: .isDirectory)
        try folder.access(refreshed: bookmarkRefreshed) { root in
            try FileManager.default.createDirectory(at: notebooks, withIntermediateDirectories: true)
            var destination = BackupDestination(root: root)
            destination.timeout = .seconds(300)
            try destination.copyOut(BackupLayout.package(item.id, in: item.trashed ? .trash : .notebooks), to: staging)
        }
        let entry: LibraryEntry
        do {
            entry = try await library.adoptPackage(at: staging, in: item.folderID, folders: catalog.folders)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if case .alreadyInLibrary = error {
                return false
            }
            throw BackupError(error)
        }
        record(entry, heldAt: item.trashed ? .trash : .notebooks)
        return true
    }

    /// The folder already holds a restored notebook file for file: record it as copied, so the next run
    /// doesn't copy it back (restoring a library would otherwise re-upload all of it).
    private func record(_ entry: LibraryEntry, heldAt location: BackupLocation) {
        let url = stateURL
        var local = LocalScan.notebook(entry, at: .notebooks, url: library.locations.packageURL(for: entry))
        LocalScan.inspect(&local)
        guard let recorded = BackupPlanner.recorded(local, at: location) else { return }
        _ = try? folder.access(refreshed: bookmarkRefreshed) { root in
            var state = BackupState.load(from: url, destination: root.path(percentEncoded: false))
            state.notebooks[entry.id] = recorded
            try state.save(to: url)
        }
    }
}

/// What the backup folder holds for this library.
public struct BackupSummary: Hashable, Sendable {
    /// End of the last run that brought it up to date.
    public var last: Date?
    public var notebooks: Int
    public var bytes: Int64

    init(_ state: BackupState) {
        last = state.lastBackup
        (notebooks, bytes) = state.totals
    }
}
