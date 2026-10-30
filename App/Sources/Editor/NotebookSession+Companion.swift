import Canvas
import Editing
import InkModel

/// Split view (#175): a second view of a notebook already open in the other pane. It opens on its owner's
/// store, edit pipeline and history with its own residency, engine and canvas; the owner's mirror feeds
/// it every accepted edit. It never writes the package, thumbnails or reading position.
extension NotebookSession {
    /// A companion's open: the owner's store, pipeline and thumbnails; its own residency and canvas, at the
    /// owner's position.
    func openCompanion(of owner: NotebookSession) async {
        _ = host
        await owner.open()
        guard !isClosed, !owner.isClosed, let store = owner.store, let edits = owner.edits else { return }
        let manifest = await store.manifest
        guard !isClosed else { return }
        self.store = store
        artwork = owner.artwork
        artworkPlacement.pageExtension = PageExtension(notebook: manifest.notebook)
        if !artwork.isEmpty {
            engine.pageArtwork = { [weak self] id in self?.artwork[id] }
        }
        let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
        let residency = PageResidency(store: store, engine: engine, pageSize: manifest.notebook.pageSize, pages: pages)
        residency.evictsFromStore = false
        residency.onPageLoaded = { [weak self] id in self?.pageLoaded(id) }
        self.residency = residency
        thumbnails = owner.thumbnails
        syncPagesModel(pages)
        engine.setTheme(manifest.notebook.theme)
        if manifest.notebook.keepsExactColors {
            state.keepsExactColors = true
            applyPalette(keepsExactColors: true)
        }
        showPages(pages.map(\.id), of: manifest.notebook, at: owner.host.readingPosition)
        if let window = host.pageWindow {
            residency.update(window)
        }
        self.edits = edits
        host.sharedUndoManager = owner.host.editUndoManager
        selection = SelectionMachine(edits: edits, display: self)
        state.onUndo = { [weak edits] in edits?.undo() }
        state.onRedo = { [weak edits] in edits?.redo() }
        owner.companionRefs.append(WeakSession(session: self))
    }

    /// Open second views of this notebook.
    var companions: [NotebookSession] {
        companionRefs.compactMap(\.session).filter { !$0.isClosed }
    }

    /// Every open view of this notebook: the owner, then its companions.
    var views: [NotebookSession] {
        let root = owner ?? self
        return [root] + root.companions
    }

    /// A companion stops: input, loading and its selection; the document stays with its owner.
    func closeCompanion() {
        isClosed = true
        engine.delegate = nil
        host.delegate = nil
        inkExtentLookup?.cancel()
        widenSettle?.cancel()
        residency?.close()
        owner?.companionRefs.removeAll { $0.session == nil || $0.session === self }
    }
}

/// A companion reference that doesn't keep it alive.
struct WeakSession {
    weak var session: NotebookSession?
}
