import CoreGraphics
import Document
import InkModel
import os

/// What ``PageResidency`` feeds: the ink engine in the app (`PageResidency(store:engine:…)`), a recording
/// fake in tests.
@MainActor
public protocol PageSink: AnyObject {
    /// Snapshots of the engine window's pages, in order (pages not in the list may be dropped).
    func setPages(_ pages: [PageSnapshot])
    /// An edit the store accepted, for a page last handed over in ``setPages(_:)`` (the echo).
    func apply(_ edit: PageEdit, to page: PageID)
    /// A loaded page is about to go to the sink: get it ready off main (the engine converts its strokes).
    func prepare(_ page: PageSnapshot) async
}

/// Page virtualization (ARCHITECTURE.md §5.2, §5.4): the notebook's page order, which pages' strokes are
/// in memory and which the engine holds, driven by the host's ``PageWindow``.
///
/// - Pages in ``PageWindow/resident`` (visible ± 3) are loaded from the `DocumentStore` in
///   ``PageWindow/loadOrder`` (page 1 first on open, then 2–3, …), at most ``maxConcurrentLoads`` at a
///   time so a fling past 100 pages doesn't queue 100 loads. Pages that leave the window are dropped
///   here and evicted from the store (`evict(page:)` checkpoints first).
/// - Pages in ``PageWindow/engine`` (visible ± 1) go to the sink via `setPages`: the loaded page, or
///   until it arrives a placeholder with the page's template and no ink, so paper and rules never pop.
///
/// The resident pages are the main-actor mirror of the store's pages. Edits go to the store first;
/// once it accepted one, ``didApply(_:to:)`` updates the mirror and echoes the edit to the sink.
/// Callers that edit a page must ``ensureLoaded(_:)`` it first so the mirror can follow; callers that
/// only read one (thumbnails, "has ink?") ``peek(_:)`` it, so the store doesn't keep it.
@MainActor
public final class PageResidency {
    /// Background loads in flight at once.
    public static let maxConcurrentLoads = 2

    /// The notebook's store.
    public let store: DocumentStore
    /// Page size for snapshots (every page; ``setPageGeometry(size:leftExtension:)`` when the notebook widens).
    public private(set) var pageSize: CGSize
    /// Paper added left of the original page (``InkModel/Notebook/leftExtension``), for snapshots.
    public private(set) var leftExtension: CGFloat = 0
    /// Pages in order.
    public private(set) var pageIDs: [PageID]
    /// Current window, if the host reported one.
    public private(set) var window: PageWindow?
    /// Called when a page's strokes reached the sink (or the mirror, outside the engine window).
    public var onPageLoaded: ((PageID) -> Void)?
    /// Called when a page leaves the window (its unflushed thumbnail should be rendered now).
    public var onPageEvicted: ((PageID) -> Void)?
    /// Pages leaving the window are released from the store too. Off for a second view of a notebook
    /// (split view, #175), which leaves the store's memory to the main one.
    public var evictsFromStore = true

    private let sink: any PageSink
    private var resident: [PageID: Page] = [:]
    private var templates: [PageID: PageTemplate]
    private var inFlight: Set<PageID> = []
    /// Loading pages an accepted edit passed by: the load may predate it, so it's read again.
    private var staleLoads: Set<PageID> = []
    private var pushed: [PushedPage] = []
    private var isClosed = false
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "canvas")

    /// What the sink was last given for a page (cheap change detection, no stroke comparison).
    private struct PushedPage: Hashable {
        var id: PageID
        var rev: UInt64?
        var template: PageTemplate
    }

    /// Creates residency for `pages` (order and templates from the manifest).
    public init(store: DocumentStore, sink: any PageSink, pageSize: CGSize, pages: [(id: PageID, template: PageTemplate)]) {
        self.store = store
        self.sink = sink
        self.pageSize = pageSize
        pageIDs = pages.map(\.id)
        templates = Dictionary(pages.map { ($0.id, $0.template) }, uniquingKeysWith: { _, last in last })
    }

    /// The loaded page, if resident.
    public func page(_ id: PageID) -> Page? {
        resident[id]
    }

    /// Whether `id` is on screen in the current window.
    public func isVisible(_ id: PageID) -> Bool {
        guard let window, let index = pageIDs.firstIndex(of: id) else { return false }
        return window.visible.contains(index)
    }

    // MARK: Window

    /// Moves the window: drops and evicts pages that left it, loads missing ones, updates the sink.
    public func update(_ window: PageWindow) {
        guard !isClosed else { return }
        self.window = window
        let wanted = wantedPages()
        for id in Array(resident.keys) where !wanted.contains(id) {
            resident[id] = nil
            onPageEvicted?(id)
            evict(id)
        }
        pushPages()
        pump()
    }

    /// Loads `id` now (bypassing the background queue) and keeps it in the mirror; for edits.
    public func ensureLoaded(_ id: PageID) async throws(DocumentError) -> Page {
        if let page = resident[id] {
            return page
        }
        let page = try await store.page(id)
        install(page)
        return resident[id] ?? page
    }

    /// Reads `id` without keeping it: the mirror's copy if resident; otherwise read from the store and
    /// released again, unless the window wants it (then it stays, as if loaded in the background).
    public func peek(_ id: PageID) async throws(DocumentError) -> Page {
        if let page = resident[id] {
            return page
        }
        let page = try await store.page(id)
        if wantedPages().contains(id) {
            install(page)
        } else {
            evict(id)
        }
        return resident[id] ?? page
    }

    // MARK: Edits

    /// The store accepted `edit` on `page`: mirror it and echo it to the sink.
    public func didApply(_ edit: PageEdit, to page: PageID) {
        if resident[page] == nil, inFlight.contains(page) {
            staleLoads.insert(page)
        }
        if var mirrored = resident[page] {
            do {
                try mirrored.apply(edit)
                resident[page] = mirrored
                if let i = pushed.firstIndex(where: { $0.id == page }) {
                    pushed[i].rev = mirrored.rev
                }
            } catch {
                Self.log.error("mirror out of sync on \(page, privacy: .public): \(String(describing: error), privacy: .public)")
                resident[page] = nil
                Task { await self.reload(page) }
                return
            }
        }
        sink.apply(edit, to: page)
    }

    /// Re-reads `page` from the store and rebuilds it in the sink (after a failed edit).
    public func reload(_ page: PageID) async {
        resident[page] = nil
        // Dropping the page from the sink discards strokes it drew but the document never accepted.
        sink.setPages(pushed.filter { $0.id != page }.compactMap { snapshot(for: $0.id) })
        pushed = []
        do throws(DocumentError) {
            try await install(store.page(page))
        } catch {
            Self.log.error("reload of \(page, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        pushPages()
    }

    // MARK: Structure

    /// New page order (insert, delete, move). Deleted pages are dropped; new pages use `templates`.
    /// Until the host reports a window for the new order, none is current.
    public func setPages(_ pages: [(id: PageID, template: PageTemplate)]) {
        pageIDs = pages.map(\.id)
        templates = Dictionary(pages.map { ($0.id, $0.template) }, uniquingKeysWith: { _, last in last })
        let ids = Set(pageIDs)
        resident = resident.filter { ids.contains($0.key) }
        window = nil
    }

    /// The template of `id` (from the manifest, or the page itself once loaded).
    public func template(of id: PageID) -> PageTemplate? {
        resident[id]?.template ?? templates[id]
    }

    /// The pages widened (#129): every snapshot the sink holds is replaced at the new size.
    public func setPageGeometry(size: CGSize, leftExtension: CGFloat) {
        guard size != pageSize || leftExtension != self.leftExtension else { return }
        pageSize = size
        self.leftExtension = leftExtension
        pushed = []
        pushPages()
    }

    /// Templates changed (the store already has them).
    public func setTemplate(_ template: PageTemplate, for ids: some Sequence<PageID>) {
        for id in ids {
            templates[id] = template
            resident[id]?.template = template
        }
        pushPages()
    }

    /// Stops loading; pages stay in the store until it is flushed.
    public func close() {
        isClosed = true
        window = nil
    }

    // MARK: Private

    private func wantedPages() -> Set<PageID> {
        guard let window else { return [] }
        return Set(window.resident.compactMap { pageIDs.indices.contains($0) ? pageIDs[$0] : nil })
    }

    private func isInEngineWindow(_ id: PageID) -> Bool {
        guard !isClosed, let window, let index = pageIDs.firstIndex(of: id) else { return false }
        return window.engine.contains(index)
    }

    /// Starts background loads in priority order, up to the concurrency limit.
    private func pump() {
        guard !isClosed, let window else { return }
        for i in window.loadOrder where inFlight.count < Self.maxConcurrentLoads && pageIDs.indices.contains(i) {
            let id = pageIDs[i]
            guard resident[id] == nil, !inFlight.contains(id) else { continue }
            inFlight.insert(id)
            let store = store
            Task {
                let result: Result<Page, DocumentError>
                do throws(DocumentError) {
                    result = try await .success(store.page(id))
                } catch {
                    result = .failure(error)
                }
                if case let .success(page) = result, isInEngineWindow(id) {
                    await sink.prepare(PageSnapshot(page: page, size: pageSize, leftExtension: leftExtension))
                }
                self.finishLoad(id, result)
            }
        }
    }

    private func finishLoad(_ id: PageID, _ result: Result<Page, DocumentError>) {
        inFlight.remove(id)
        if staleLoads.remove(id) != nil, case .success = result {
            // An edit landed while it loaded: the next pump reads it again.
            return pump()
        }
        switch result {
        case let .success(page):
            if !isClosed, wantedPages().contains(id) {
                install(page)
            } else {
                // Scrolled past while loading: don't let the store keep it.
                evict(id)
            }
        case let .failure(error):
            Self.log.error("load of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        pump()
    }

    /// Adds a loaded page to the mirror unless a newer one is already there, then feeds the sink.
    private func install(_ page: Page) {
        guard pageIDs.contains(page.id) else { return }
        if let existing = resident[page.id], existing.rev >= page.rev {
            return
        }
        var page = page
        if let template = templates[page.id] {
            page.template = template
        }
        resident[page.id] = page
        pushPages()
        onPageLoaded?(page.id)
    }

    /// Releases `id` from the store unless, by the time it runs, the page is resident or loading again.
    private func evict(_ id: PageID) {
        guard evictsFromStore else { return }
        let store = store
        Task {
            guard resident[id] == nil, !inFlight.contains(id) else { return }
            do {
                try await store.evict(page: id)
            } catch {
                Self.log.error("evict of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Hands the sink the snapshots of the engine window if anything about them changed.
    private func pushPages() {
        guard !isClosed, let window else { return }
        let ids = window.engine.compactMap { pageIDs.indices.contains($0) ? pageIDs[$0] : nil }
        let next = ids.map { PushedPage(id: $0, rev: resident[$0]?.rev, template: templates[$0] ?? .blank) }
        guard next != pushed else { return }
        pushed = next
        sink.setPages(ids.compactMap(snapshot))
    }

    private func snapshot(for id: PageID) -> PageSnapshot? {
        if let page = resident[id] {
            return PageSnapshot(page: page, size: pageSize, leftExtension: leftExtension)
        }
        // Not loaded yet: template only, flagged so the engine shows the page's thumbnail, not a blank page.
        return PageSnapshot(
            page: Page(id: id, template: templates[id] ?? .blank), size: pageSize, leftExtension: leftExtension, isLoaded: false
        )
    }
}

#if canImport(UIKit)
    import InkEngine

    public extension PageResidency {
        /// Residency feeding `engine`.
        convenience init(store: DocumentStore, engine: any InkEngine, pageSize: CGSize, pages: [(id: PageID, template: PageTemplate)]) {
            self.init(store: store, sink: EngineSink(engine: engine), pageSize: pageSize, pages: pages)
        }
    }

    /// The ink engine as a ``PageSink``.
    private final class EngineSink: PageSink {
        let engine: any InkEngine

        init(engine: any InkEngine) {
            self.engine = engine
        }

        func setPages(_ pages: [PageSnapshot]) {
            engine.setPages(pages)
        }

        func apply(_ edit: PageEdit, to page: PageID) {
            engine.apply(edit, to: page)
        }

        func prepare(_ page: PageSnapshot) async {
            await engine.prepare(page)
        }
    }
#endif
