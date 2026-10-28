import Document
import InkModel

/// Automatic new pages (#172) for ``EditPipeline/addsPagesAutomatically``: one blank page waits at the end.
///
/// ```
/// edit on one of the last pages / page order changed ─▶ changed ─▶ (after the change) settle():
///   last page has content            ─▶ append a blank page with its template
///   blank pages it added at the end  ─▶ keep the first (none if the page before is blank too)
/// ```
///
/// Runs on the pipeline's queue, never as an undo step. Only pages added here are removed again, and
/// only this session's.
@MainActor
final class TrailingPages {
    var isOn = false {
        didSet { changed = changed || (isOn && !oldValue) }
    }

    /// The last pages' content or the page order changed since the last ``settle()``.
    var changed = false

    private let store: DocumentStore
    private let mirror: any PageMirror
    private var added: Set<PageID> = []

    init(store: DocumentStore, mirror: any PageMirror) {
        self.store = store
        self.mirror = mirror
    }

    /// `page` was edited: settle if it is the last page or just before the pages added at the end.
    func didEdit(_ page: PageID) {
        guard isOn, !changed else { return }
        let ids = mirror.pageIDs
        guard let index = ids.lastIndex(of: page) else { return }
        let addedAtEnd = ids.reversed().prefix { added.contains($0) }.count
        changed = index >= ids.count - 1 - addedAtEnd
    }

    /// Appends a blank page after a last page with content, or removes the extra blank pages added at the
    /// end (all of them when the page before is blank too).
    func settle() async throws {
        guard isOn else { return }
        let ids = mirror.pageIDs
        guard !ids.isEmpty else { return }
        let blank = try await addedBlankPages(ids)
        let before = ids.dropLast(blank.count).last
        let beforeIsBlank = if let before {
            try await isBlank(before)
        } else {
            false
        }
        if blank.isEmpty {
            guard !beforeIsBlank else { return }
            let template = await store.manifest.pages.last?.template
            try await added.insert(store.insertPage(at: ids.count, template: template))
        } else {
            let removed = beforeIsBlank ? blank : Array(blank.dropLast())
            guard !removed.isEmpty else { return }
            for id in removed {
                try await store.deletePage(id)
            }
        }
        await mirror.pagesDidChange()
    }

    /// Stops, and deletes the blank pages added at the end from the store (none left behind), never every page.
    func close() async throws {
        guard isOn else { return }
        isOn = false
        let ids = await store.manifest.pages.map(\.id)
        let blank = try await addedBlankPages(ids)
        for id in blank where blank.count < ids.count {
            try await store.deletePage(id)
        }
    }

    /// The blank pages at the end that were added here, last first.
    private func addedBlankPages(_ ids: [PageID]) async throws -> [PageID] {
        var blank: [PageID] = []
        for id in ids.reversed() {
            guard added.contains(id), try await isBlank(id) else { break }
            blank.append(id)
        }
        return blank
    }

    /// Whether `id` has no strokes or images; a page the store had to load is evicted again.
    private func isBlank(_ id: PageID) async throws -> Bool {
        if let page = mirror.page(id) {
            return page.isEmpty
        }
        let wasLoaded = await store.isLoaded(id)
        let page = try await store.page(id)
        if !wasLoaded {
            try? await store.evict(page: id)
        }
        return page.isEmpty
    }
}
