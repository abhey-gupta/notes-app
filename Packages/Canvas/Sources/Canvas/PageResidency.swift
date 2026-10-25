#if canImport(UIKit)
    import CoreGraphics
    import Document
    import InkEngine
    import InkModel
    import os

    /// Page virtualization (ARCHITECTURE.md §5.2, §5.4): which pages' strokes are in memory and which
    /// the engine holds, driven by the host's ``PageWindow``.
    ///
    /// - Pages in ``PageWindow/resident`` (visible ± 3) are loaded from the `DocumentStore` in
    ///   ``PageWindow/loadOrder`` (page 1 first on open, then 2–3, …), at most ``maxConcurrentLoads`` at a
    ///   time so a fling past 100 pages doesn't queue 100 loads. Pages that leave the window are dropped
    ///   here and evicted from the store (`evict(page:)` checkpoints first).
    /// - Pages in ``PageWindow/engine`` (visible ± 1) go to the engine via `setPages`: the loaded page, or
    ///   until it arrives a placeholder with the page's template and no ink, so paper and rules never pop.
    ///
    /// The resident pages are the main-actor mirror of the store's pages. Edits go to the store first;
    /// once it accepted one, ``didApply(_:to:)`` updates the mirror and echoes the edit to the engine.
    /// Callers that edit a page must ``ensureLoaded(_:)`` it first so the mirror can follow.
    @MainActor
    public final class PageResidency {
        /// Background loads in flight at once.
        public static let maxConcurrentLoads = 2

        /// The notebook's store.
        public let store: DocumentStore
        /// The engine fed with snapshots.
        public let engine: any InkEngine
        /// Page size for snapshots.
        public let pageSize: CGSize
        /// Pages in order.
        public private(set) var pageIDs: [PageID]
        /// Loaded pages (the mirror).
        public private(set) var resident: [PageID: Page] = [:]
        /// Current window, if the host reported one.
        public private(set) var window: PageWindow?
        /// Called when a page's strokes reached the engine (or the mirror, outside the engine window).
        public var onPageLoaded: ((PageID) -> Void)?
        /// Called when a page leaves the window (its unflushed thumbnail should be rendered now).
        public var onPageEvicted: ((PageID) -> Void)?

        private var templates: [PageID: PageTemplate]
        private var inFlight: Set<PageID> = []
        private var pushed: [PushedPage] = []
        private var isClosed = false
        private static let log = Logger(subsystem: "com.abhey.notespace", category: "canvas")

        /// What the engine was last given for a page (cheap change detection, no stroke comparison).
        private struct PushedPage: Hashable {
            var id: PageID
            var rev: UInt64?
            var template: PageTemplate
        }

        /// Creates residency for `pages` (order and templates from the manifest).
        public init(store: DocumentStore, engine: any InkEngine, pageSize: CGSize, pages: [(id: PageID, template: PageTemplate)]) {
            self.store = store
            self.engine = engine
            self.pageSize = pageSize
            pageIDs = pages.map(\.id)
            templates = Dictionary(pages.map { ($0.id, $0.template) }, uniquingKeysWith: { _, last in last })
        }

        /// The loaded page, if resident.
        public func page(_ id: PageID) -> Page? {
            resident[id]
        }

        // MARK: Window

        /// Moves the window: drops and evicts pages that left it, loads missing ones, updates the engine.
        public func update(_ window: PageWindow) {
            guard !isClosed else { return }
            self.window = window
            let wanted = wantedPages()
            for id in Array(resident.keys) where !wanted.contains(id) {
                resident[id] = nil
                onPageEvicted?(id)
                evict(id)
            }
            pushEngine()
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

        // MARK: Edits

        /// The store accepted `edit` on `page`: mirror it and echo it to the engine.
        public func didApply(_ edit: PageEdit, to page: PageID) {
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
            engine.apply(edit, to: page)
        }

        /// Re-reads `page` from the store and rebuilds it in the engine (after a failed edit).
        public func reload(_ page: PageID) async {
            resident[page] = nil
            // Dropping the page from the engine discards strokes it drew but the document never accepted.
            engine.setPages(pushed.filter { $0.id != page }.compactMap { snapshot(for: $0.id) })
            pushed = []
            do throws(DocumentError) {
                try await install(store.page(page))
            } catch {
                Self.log.error("reload of \(page, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            pushEngine()
        }

        // MARK: Structure

        /// New page order (insert, delete, move). Deleted pages are dropped; new pages use `templates`.
        public func setPages(_ pages: [(id: PageID, template: PageTemplate)]) {
            pageIDs = pages.map(\.id)
            templates = Dictionary(pages.map { ($0.id, $0.template) }, uniquingKeysWith: { _, last in last })
            let ids = Set(pageIDs)
            resident = resident.filter { ids.contains($0.key) }
            window = nil
        }

        /// Templates changed (the store already has them).
        public func setTemplate(_ template: PageTemplate, for ids: some Sequence<PageID>) {
            for id in ids {
                templates[id] = template
                resident[id]?.template = template
            }
            pushEngine()
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
                    self.finishLoad(id, result)
                }
            }
        }

        private func finishLoad(_ id: PageID, _ result: Result<Page, DocumentError>) {
            inFlight.remove(id)
            switch result {
            case let .success(page):
                if !isClosed, wantedPages().contains(id) {
                    install(page)
                } else if resident[id] == nil {
                    // Scrolled past while loading: don't let the store keep it.
                    evict(id)
                }
            case let .failure(error):
                Self.log.error("load of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
            pump()
        }

        /// Adds a loaded page to the mirror unless a newer one is already there, then feeds the engine.
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
            pushEngine()
            onPageLoaded?(page.id)
        }

        private func evict(_ id: PageID) {
            let store = store
            Task {
                do {
                    try await store.evict(page: id)
                } catch {
                    Self.log.error("evict of \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
        }

        /// Hands the engine the snapshots of the engine window if anything about them changed.
        private func pushEngine() {
            guard !isClosed, let window else { return }
            let ids = window.engine.compactMap { pageIDs.indices.contains($0) ? pageIDs[$0] : nil }
            let next = ids.map { PushedPage(id: $0, rev: resident[$0]?.rev, template: templates[$0] ?? .blank) }
            guard next != pushed else { return }
            pushed = next
            engine.setPages(ids.compactMap(snapshot))
        }

        private func snapshot(for id: PageID) -> PageSnapshot? {
            if let page = resident[id] {
                return PageSnapshot(page: page, size: pageSize)
            }
            // Not loaded yet: template only, flagged so the engine shows the page's thumbnail, not a blank page.
            return PageSnapshot(page: Page(id: id, template: templates[id] ?? .blank), size: pageSize, isLoaded: false)
        }
    }
#endif
