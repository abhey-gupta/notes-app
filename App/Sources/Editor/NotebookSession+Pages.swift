import Canvas
import Document
import Editing
import InkModel

/// Page structure (pages overview, #32): insert, delete, move, each one undo step (`PageStructureEdit`).
///
/// ```
/// overview ─▶ session.insert/delete/move ─▶ EditPipeline ─▶ store (manifest) ─▶ refreshPages: residency.setPages,
///   host.layout, overview entries ─▶ EditStack.record(structure:)
/// undo/redo ─▶ EditPipeline ─▶ same path (a restored page gets its ink back as one .add)
/// ```
extension NotebookSession {
    func installPages() {
        let pages = state.pages
        pages.onShow = { [weak self] in self?.showPage($0) }
        pages.onInsert = { [weak self] index, style in self?.insertPage(after: index, template: style.defaultTemplate) }
        pages.onMove = { [weak self] from, to in self?.movePage(from: from, to: to) }
        pages.onDelete = { [weak self] in self?.deletePages($0) }
        pages.hasInk = { [weak self] ids in await self?.pagesHaveInk(ids) ?? false }
    }

    /// Closes the overview and puts the page at `index` on screen.
    func showPage(_ index: Int) {
        state.pages.dismiss()
        guard host.layout.pageIDs.indices.contains(index) else { return }
        host.scrollToPage(index, animated: false)
    }

    /// Inserts an empty page after `index` (`nil` appends) and scrolls to it.
    func insertPage(after index: Int?, template: PageTemplate?) {
        edits?.insertPage(after: index, template: template) { [weak self] at in
            guard let self else { return }
            host.scrollToPage(at, animated: !state.pages.isPresented)
        }
    }

    /// Deletes `ids` as one undo step; the entry keeps each page's ink so undo brings it back.
    func deletePages(_ ids: [PageID]) {
        edits?.deletePages(ids)
    }

    func movePage(from source: Int, to destination: Int) {
        edits?.movePage(from: source, to: destination)
    }

    /// Whether any of `ids` has strokes or photos; pages not in memory are read and released again.
    func pagesHaveInk(_ ids: [PageID]) async -> Bool {
        guard let residency else { return false }
        for id in ids {
            if let page = try? await residency.peek(id), !page.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: Following the manifest

    /// Layout, residency, overview entries and the library follow the manifest's page order.
    func refreshPages() async {
        guard let store, let residency else { return }
        let manifest = await store.manifest
        let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
        residency.setPages(pages)
        host.pageExtension = PageExtension(notebook: manifest.notebook)
        host.layout = PageLayout(pageIDs: pages.map(\.id), pageSize: manifest.notebook.pageSize, footer: CanvasHostView.footerHeight)
        if let window = host.pageWindow {
            residency.update(window)
        }
        syncPagesModel(pages)
        library.documentDidSave(manifest)
    }

    func syncPagesModel(_ pages: [(id: PageID, template: PageTemplate)]) {
        let thumbnails = thumbnails
        state.pages.setEntries(pages.map {
            PagesModel.Entry(id: $0.id, pattern: $0.template.pattern, thumbnail: thumbnails?.thumbnailURL(for: $0.id))
        })
    }
}
