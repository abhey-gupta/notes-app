import Canvas
import Document
import InkModel
import Tools

/// Page structure (pages overview, #32): insert, delete, move, each one undo step (`PageStructureEdit`).
///
/// ```
/// overview ─▶ session.insert/delete/move ─▶ store (manifest) ─▶ refreshPages: residency.setPages,
///   host.layout, overview entries ─▶ EditStack.record(structure:)
/// undo/redo ─▶ applyStructure(entry.structure) ─▶ same path (a restored page gets its ink back as one .add)
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
        enqueue("insert page") { [weak self] in
            guard let self, let store, let residency else { return }
            let at = index.map { min($0 + 1, residency.pageIDs.count) } ?? residency.pageIDs.count
            let template = if let template {
                template
            } else {
                await store.manifest.notebook.paper.defaultTemplate
            }
            let id = try await store.insertPage(at: at, template: template)
            await refreshPages()
            state.edits.record(structure: [.insert(id, at: at, template: template, strokes: [])], actionName: "Add Page")
            host.scrollToPage(at, animated: !state.pages.isPresented)
        }
    }

    /// Deletes `ids` as one undo step; the entry keeps each page's ink so undo brings it back.
    func deletePages(_ ids: [PageID]) {
        enqueue("delete pages") { [weak self] in
            guard let self, let store, let residency else { return }
            let wanted = Set(ids)
            var pages: [PageStructureEdit.Removal] = []
            for (index, id) in residency.pageIDs.enumerated() where wanted.contains(id) {
                let page = try await store.page(id)
                pages.append(.init(id: id, index: index, template: page.template, strokes: page.strokes))
            }
            guard !pages.isEmpty, pages.count < residency.pageIDs.count else { return }
            let edits = PageStructureEdit.deleting(pages)
            try await applyStructure(edits)
            state.edits.record(structure: edits, actionName: pages.count == 1 ? "Delete Page" : "Delete Pages")
        }
    }

    func movePage(from source: Int, to destination: Int) {
        guard source != destination else { return }
        enqueue("move page") { [weak self] in
            guard let self, let residency else { return }
            let range = residency.pageIDs.indices
            guard range.contains(source), range.contains(destination) else { return }
            let edit = PageStructureEdit.move(from: source, to: destination)
            try await applyStructure([edit])
            state.edits.record(structure: [edit], actionName: "Move Page")
        }
    }

    /// Whether any of `ids` has strokes; pages not in memory are read and released again.
    func pagesHaveInk(_ ids: [PageID]) async -> Bool {
        guard let store, let residency else { return false }
        for id in ids {
            if let page = residency.page(id) {
                if !page.strokes.isEmpty {
                    return true
                }
                continue
            }
            guard let page = try? await store.page(id) else { continue }
            if residency.page(id) == nil {
                try? await store.evict(page: id)
            }
            if !page.strokes.isEmpty {
                return true
            }
        }
        return false
    }

    // MARK: Applying

    /// Applies structure edits (one entry's worth) to the store, refreshes layout and residency once,
    /// then gives restored pages their ink back. Runs on the edit queue.
    func applyStructure(_ edits: [PageStructureEdit]) async throws {
        guard let store, let residency else { return }
        var restored: [(id: PageID, strokes: [Stroke])] = []
        for edit in edits {
            switch edit {
            case let .insert(id, index, template, strokes):
                try await store.insertPage(id: id, at: index, template: template)
                if !strokes.isEmpty {
                    restored.append((id, strokes))
                }
            case let .delete(id, _, _, _):
                try await store.deletePage(id)
            case let .move(from, to):
                try await store.movePage(from: from, to: to)
            }
        }
        await refreshPages()
        for (id, strokes) in restored {
            let page = try await residency.ensureLoaded(id)
            try await commit(page.addEdit(strokes), to: id)
        }
    }

    /// Layout, residency, overview entries and the library follow the manifest's page order.
    func refreshPages() async {
        guard let store, let residency else { return }
        let manifest = await store.manifest
        let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
        residency.setPages(pages)
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
