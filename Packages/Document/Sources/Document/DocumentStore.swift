import CoreGraphics
import Darwin
import Dispatch
import Foundation
import InkModel
import os

/// The single owner of one open notebook's data: loaded pages, edits, autosave (ARCHITECTURE.md §4.4).
///
/// There is no Save. Every ``apply(_:to:)`` updates the in-memory page and appends the edit to the
/// page's journal, `pages/<id>.wal`, before returning. A checkpoint folds journals into the stroke files
/// and manifest: after ``Options/idleDelay`` without edits, on ``evict(page:)`` (page scrolled away), on
/// ``flush()`` (app backgrounds / resigns active), or as soon as a page's journal passes
/// ``Options/journalLimit``. Loading a page replays its journal first, so a page always comes back as
/// it was when the last ``apply(_:to:)`` returned.
///
/// Pages load lazily and individually (``page(_:)``); nothing else is read until asked for.
///
/// ## Durability
/// `apply` returns only after its record is written and `fcntl(F_BARRIERFSYNC)`'d (`fsync` where
/// unsupported). Hence:
/// - **App crash, kill, jetsam, watchdog** (the realistic cases): every edit whose `apply` returned is
///   recovered. A kill mid-append loses only that edit (its torn record is detected and cut off).
/// - **Kernel panic or sudden power loss**: the journal recovers to a consistent prefix in commit order
///   (the barrier forbids reordering); the newest edits may be lost if they were still in the drive's
///   volatile cache. Never torn, never reordered, never garbage ink. `F_FULLFSYNC` would close that window
///   at ~8× the sync cost (p50 2.0 vs 0.27 ms on an M-series Mac); iPads have batteries, so we take the
///   barrier (as SQLite's WAL mode does on Apple platforms).
/// - Checkpoints write stroke files and the manifest via temp file + barrier sync + `rename`, then delete
///   journals. A crash at any point leaves either the journal (replayed) or the new stroke file (a stale
///   journal is recognized by its base identity and discarded), never neither.
///
/// ## Threading
/// Runs on its own serial dispatch queue, not the cooperative pool, because appends block on `fsync`.
/// Nothing here touches the main thread. Errors are typed ``DocumentError``s; a failed `apply` changes
/// nothing in memory or on disk.
///
/// ## Instrumentation
/// Emits `os` signposts `doc.checkpoint` and `doc.append` (subsystem `com.abhey.notespace`, category
/// `doc`, matching the `Perf` package's names) and reports ``Event``s to ``Options/onEvent`` so the app
/// can feed the debug HUD without this package depending on `Perf` (which is iOS/UIKit-only).
public actor DocumentStore {
    /// Tuning and hooks.
    public struct Options: Sendable {
        /// Idle time after the last edit before dirty pages are checkpointed; `nil` disables the idle
        /// checkpoint (tests). Default 2 s.
        public var idleDelay: Duration?
        /// Journal size (bytes) past which a page is checkpointed right after the append. Default 1 MiB.
        public var journalLimit: Int
        /// Called on the store's queue for each ``Event``. Keep it cheap.
        public var onEvent: (@Sendable (Event) -> Void)?

        /// Creates options.
        public init(idleDelay: Duration? = .seconds(2), journalLimit: Int = 1 << 20, onEvent: (@Sendable (Event) -> Void)? = nil) {
            self.idleDelay = idleDelay
            self.journalLimit = journalLimit
            self.onEvent = onEvent
        }
    }

    /// Instrumentation events (debug HUD, perf tests).
    public enum Event: Sendable, Hashable {
        /// An edit was journaled and is durable. `duration` covers encode + write + sync.
        case appended(page: PageID, recordBytes: Int, journalBytes: Int, duration: Duration)
        /// Dirty pages were written to stroke files + manifest and their journals deleted.
        case checkpointed(pages: Int, duration: Duration)
        /// A page's journal was replayed on load. `discardedBytes` > 0 means a torn or damaged tail was
        /// cut off (or a stale journal deleted).
        case recovered(page: PageID, replayedEdits: Int, discardedBytes: Int)
    }

    /// Package root.
    public nonisolated let url: URL

    private var package: NotebookPackage
    private var loaded: [PageID: LoadedPage] = [:]
    private let options: Options
    private let queue: DispatchSerialQueue
    private var lastEdit = ContinuousClock.now
    private var idleTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "doc")
    private static let signposter = OSSignposter(subsystem: "com.abhey.notespace", category: "doc")

    /// Serial queue executor: blocking file I/O stays off the cooperative pool.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Takes ownership of an opened package. Don't use `package` (or a second store on the same URL)
    /// afterwards: the store assumes it is the only writer.
    public init(package: NotebookPackage, options: Options = Options()) {
        url = package.url
        self.package = package
        self.options = options
        queue = DispatchSerialQueue(label: "com.abhey.notespace.document", qos: .userInitiated)
    }

    /// Opens the package at `url` (reads only the manifest).
    public init(opening url: URL, options: Options = Options()) throws(DocumentError) {
        try self.init(package: NotebookPackage.open(at: url), options: options)
    }

    deinit {
        idleTask?.cancel()
    }

    // MARK: Reading

    /// Manifest as of the last checkpoint or page-structure change. Per-page `rev`s lag behind
    /// unflushed edits; ``page(_:)`` has the live rev.
    public var manifest: Manifest {
        package.manifest
    }

    /// Imported PDF artwork by page; see ``NotebookPackage/artwork()``. Opens the PDFs, reads no pages.
    public func artwork() -> [PageID: any PageArtwork] {
        package.artwork()
    }

    /// The page with every applied edit, loading it (stroke file + journal replay) on first use.
    public func page(_ id: PageID) throws(DocumentError) -> Page {
        try load(id).page
    }

    /// Whether `id` is in memory.
    public func isLoaded(_ id: PageID) -> Bool {
        loaded[id] != nil
    }

    /// Bytes in `id`'s journal on disk (0 when checkpointed or not loaded). For the debug HUD.
    public func journalSize(of id: PageID) -> Int {
        loaded[id]?.journal.size ?? 0
    }

    // MARK: Editing

    /// Applies `edit` to page `id` and makes it durable before returning.
    ///
    /// Order: apply to a copy (validates), append + sync the journal record, then adopt the copy. On any
    /// error nothing changes. Bumps the page `rev` and arms the idle checkpoint.
    /// - Returns: The rect to invalidate (union of touched stroke bounds, before and after).
    /// - Throws: ``DocumentError/invalidEdit(_:_:)`` if `edit` does not apply,
    ///   ``DocumentError/pageTooLarge(_:)`` if the record is too large to journal, `.io` on write failure.
    @discardableResult
    public func apply(_ edit: PageEdit, to id: PageID) throws(DocumentError) -> CGRect {
        let state = try load(id)
        let start = ContinuousClock.now
        let interval = Self.signposter.beginInterval("doc.append")
        defer { Self.signposter.endInterval("doc.append", interval) }

        var next = state.page
        let dirty: CGRect
        do {
            dirty = try next.apply(edit)
        } catch {
            throw .invalidEdit(id, error)
        }
        let record: [UInt8]
        do {
            record = try Journal.encodeRecord(rev: next.rev, edit: edit)
        } catch {
            throw .pageTooLarge(id)
        }
        try state.journal.append(record, header: Journal.Header(baseRev: state.page.rev, base: state.base))
        state.page = next
        state.isDirty = true

        options.onEvent?(.appended(
            page: id, recordBytes: record.count, journalBytes: state.journal.size, duration: ContinuousClock.now - start
        ))
        if state.journal.size > options.journalLimit {
            // The edit is already durable; a failed checkpoint just leaves the journal for the next try.
            do {
                try checkpoint([id])
            } catch {
                Self.log
                    .error("checkpoint of \(id, privacy: .public) at journal limit failed: \(String(describing: error), privacy: .public)")
            }
        }
        armIdleCheckpoint()
        return dirty
    }

    // MARK: Checkpoints

    /// Checkpoints every dirty page (one manifest write). Call when the app backgrounds or resigns
    /// active. Cancels a pending idle checkpoint.
    public func flush() throws(DocumentError) {
        idleTask?.cancel()
        idleTask = nil
        try checkpoint(Array(loaded.keys))
    }

    /// Checkpoints page `id` if dirty, then drops it from memory (page scrolled out of the window).
    /// No-op if the page is not loaded.
    public func evict(page id: PageID) throws(DocumentError) {
        guard loaded[id] != nil else { return }
        try checkpoint([id])
        loaded[id] = nil
    }

    /// Writes the dirty pages among `ids` to their stroke files and the manifest, then deletes their
    /// journals. Signposted `doc.checkpoint`.
    private func checkpoint(_ ids: [PageID]) throws(DocumentError) {
        let targets = ids.compactMap { id in loaded[id].flatMap { $0.isDirty ? $0 : nil } }
        guard !targets.isEmpty else { return }
        let start = ContinuousClock.now
        let interval = Self.signposter.beginInterval("doc.checkpoint")
        defer { Self.signposter.endInterval("doc.checkpoint", interval) }

        let identities = try package.checkpoint(targets.map(\.page))
        for state in targets {
            state.base = identities[state.page.id] ?? state.base
            state.isDirty = false
            // Failure here is harmless: the journal's base no longer matches, so load discards it.
            do {
                try state.journal.delete()
            } catch {
                Self.log.error("could not delete journal: \(String(describing: error), privacy: .public)")
            }
        }
        options.onEvent?(.checkpointed(pages: targets.count, duration: ContinuousClock.now - start))
    }

    /// One debounce task per idle period: each edit just moves ``lastEdit``; the task re-sleeps until
    /// `lastEdit + idleDelay` has passed with no newer edit, then checkpoints. Holds the store weakly.
    private func armIdleCheckpoint() {
        guard let delay = options.idleDelay else { return }
        lastEdit = .now
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            var deadline = ContinuousClock.now + delay
            while true {
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled, let self, let later = await idleCheckpointDue() else { return }
                deadline = later
            }
        }
    }

    /// Checkpoints if the idle delay has elapsed since the last edit (returns `nil`); otherwise returns
    /// the new deadline.
    private func idleCheckpointDue() -> ContinuousClock.Instant? {
        guard let delay = options.idleDelay else { return nil }
        let deadline = lastEdit + delay
        if ContinuousClock.now < deadline {
            return deadline
        }
        idleTask = nil
        do {
            try checkpoint(Array(loaded.keys))
        } catch {
            Self.log.error("idle checkpoint failed: \(String(describing: error), privacy: .public)")
        }
        return nil
    }

    // MARK: Page structure

    /// Inserts an empty page; see ``NotebookPackage/insertPage(id:at:template:)``.
    @discardableResult
    public func insertPage(id: PageID = PageID(), at index: Int? = nil, template: PageTemplate? = nil) throws(DocumentError) -> PageID {
        try package.insertPage(id: id, at: index, template: template)
    }

    /// Deletes a page, its stroke file, journal and thumbnail; any unflushed edits to it are dropped.
    public func deletePage(_ id: PageID) throws(DocumentError) {
        try package.deletePage(id)
        loaded[id] = nil
    }

    /// Moves the page at `source` to `destination`; see ``NotebookPackage/movePage(from:to:)``.
    public func movePage(from source: Int, to destination: Int) throws(DocumentError) {
        try package.movePage(from: source, to: destination)
    }

    /// Sets the background template of `ids` (all pages if `nil`), in the manifest and in loaded pages.
    /// Templates aren't journaled: the manifest is written before this returns.
    public func setTemplate(_ template: PageTemplate, for ids: [PageID]? = nil) throws(DocumentError) {
        try package.setTemplate(template, for: ids)
        for id in ids ?? package.manifest.notebook.pages {
            loaded[id]?.page.template = template
        }
    }

    /// Changes notebook metadata and writes the manifest.
    public func updateNotebook(_ change: @Sendable (inout Notebook) -> Void) throws(DocumentError) {
        try package.updateNotebook(change)
    }

    // MARK: Loading

    private func load(_ id: PageID) throws(DocumentError) -> LoadedPage {
        if let state = loaded[id] {
            return state
        }
        let (base, identity) = try package.loadPageAndIdentity(id)
        let journal = JournalFile(url: package.journalURL(for: id), directory: package.pagesDirectory)
        let data = try journal.read()
        let recovery = try Journal.recover(base, identity: identity, journal: data)
        let discarded = try journal.settle(recovery, fileSize: data?.count ?? 0)
        if let damage = recovery.damage {
            Self.log.error("""
            journal for page \(id, privacy: .public) damaged (\(String(describing: damage.kind), privacy: .public) \
            at byte \(damage.offset)); kept \(recovery.replayed) edits, dropped \(discarded) bytes
            """)
        } else if recovery.stale {
            Self.log.info("stale journal for page \(id, privacy: .public) discarded (already checkpointed)")
        }
        if data != nil {
            options.onEvent?(.recovered(page: id, replayedEdits: recovery.replayed, discardedBytes: discarded))
        }
        let state = LoadedPage(page: recovery.page, base: identity, journal: journal, isDirty: recovery.isDirty)
        loaded[id] = state
        if let version = recovery.header?.version, version < Journal.formatVersion {
            // Written by an older build: fold it in now so new records never land in an old-format journal.
            do {
                if state.isDirty {
                    try checkpoint([id])
                } else {
                    try journal.delete()
                }
            } catch {
                loaded[id] = nil
                throw error
            }
        }
        if state.isDirty {
            armIdleCheckpoint()
        }
        return state
    }
}
