import Canvas
import CoreGraphics
import enum DesignSystem.Tokens
import Document
import Editing
import Foundation
import InkEngine
import InkEnginePencilKit
import InkModel
import os
import Perf
import Tools

/// One open notebook in the editor: the wiring between canvas, engine, document and history
/// (ARCHITECTURE.md §3.1, §4.4, §6, §8).
///
/// ```
/// Pencil ─▶ engine ─didCommit/eraser─▶ session ─▶ EditPipeline ─▶ DocumentStore.apply (journaled)
///                                                       ├─▶ PageResidency.didApply ─▶ mirror + engine.apply (echo)
///                                                       └─▶ EditStack.record ─▶ UndoManagerBridge (⌘Z, 3-finger)
/// undo/redo ─▶ EditPipeline ─inverse─▶ same path (store first, then mirror + engine)
/// scroll ─▶ CanvasHostView ─PageWindow─▶ PageResidency ─▶ store.page / store.evict, engine.setPages
/// thumbnails, "has ink?" ─▶ PageResidency.peek (mirror, or read and released)
/// ```
///
/// Every change goes through ``edits`` (`EditPipeline`), one at a time in arrival order, so the next
/// edit (a second stroke, the next eraser batch, an undo) always sees the state the store has. The
/// engine draws a committed stroke itself until the echo arrives, so the hop costs no visible latency.
///
/// Lifecycle: ``open()`` (from `.task`), ``flush()`` when the scene leaves the foreground, ``close()``
/// when the editor goes away. Closing flushes in the background; reopening the same notebook waits for
/// that flush so a package never has two writers.
///
/// Split view (#175): a notebook in both panes gets a companion (``init(companionOf:)``), a second canvas,
/// engine and page residency on the same open store, edit pipeline and history. Every edit the store
/// accepts reaches both mirrors and engines (`ResidencyMirror` followers), so ink drawn in one pane shows
/// in the other; the owner alone writes the package, thumbnails and the library entry.
@MainActor
final class NotebookSession {
    /// The canvas host (and through it the engine), created on first use so building an `EditorScreen`
    /// value stays cheap.
    private(set) lazy var host: CanvasHostView = makeHost()
    /// Chrome state and the notebook's history.
    let state: EditorState
    let notebookID: NotebookID

    let library: any LibraryModel
    let initialPageCount: Int
    let initialPageSize: CGSize
    var initialTheme: PaperTheme
    var store: DocumentStore?
    /// Imported PDF pages by page ID (#119): the engine draws them under the ink, export flattens onto them.
    var artwork: [PageID: any PageArtwork] = [:]
    /// Where artwork sits on widened pages; follows the manifest (``refreshPages()``).
    let artworkPlacement = ArtworkPlacement()
    var residency: PageResidency?
    /// Page thumbs + cover (`+Thumbnails`, §5.5): fed on every accepted edit, flushed with the store.
    var thumbnails: ThumbnailService?
    var thumbnailRegeneration: Task<Void, Never>?
    /// Overview cells on screen whose pages may lack a thumbnail, oldest first (`+Thumbnails`, #207).
    var thumbnailWants: [PageID] = []
    var thumbnailFill: Task<Void, Never>?
    /// The one path for changes to the notebook (strokes, erasing, selection, pages, undo); set by ``open()``.
    var edits: EditPipeline?
    /// Automatic new pages (#172): a blank page waits at the end instead of the add-page button.
    var addsPagesAutomatically = false {
        didSet {
            host.showsAddPage = !addsPagesAutomatically
            edits?.addsPagesAutomatically = addsPagesAutomatically
        }
    }

    /// The toolbar's current tool (``setTool(_:allowsFingerDrawing:snapsShapes:holdsToErase:)``); erasing reads its mode and size.
    var tool = ActiveTool.ink(.ballpoint, color: .primary, width: 2)
    /// Lift after an eraser stroke (#156: the toolbar may switch back).
    var onErased: (() -> Void)?
    /// A pen touch held still (#211): the toolbar switches to the eraser until lift (``onErased``).
    var onHoldErase: (() -> Void)?
    var isErasing = false
    var isClosed = false
    private var awaitingFirstPage = true
    var awaitingFirstSharp = true
    /// Lasso selection (`+Selection`); set by ``open()``.
    var selection: SelectionMachine?
    let selectionOverlay = SelectionOverlayView()
    /// Pages expanding sideways (`+Width`, #129): the ink-extent lookup of a grab, the pages whose sharp
    /// ink lifts the frozen frame after a widen, and the timeout that lifts it anyway.
    var inkExtentLookup: Task<Void, Never>?
    var awaitingSharpInk: Set<PageID> = []
    var widenSettle: Task<Void, Never>?

    /// The notebook's own session when this is a second view of it (split view, #175).
    weak var owner: NotebookSession?
    let isCompanion: Bool
    /// This notebook's second views (owner only, `+Companion`).
    var companionRefs: [WeakSession] = []
    private var opening: Task<Void, Never>?
    /// Counted in ``openNotebooks`` (from opening the package until the close's last checkpoint).
    private var holdsPackage = false

    private static var closing: [NotebookID: Task<Void, Never>] = [:]

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "editor")

    init(notebook: NotebookSummary, library: any LibraryModel, startsFocused: Bool = false) {
        notebookID = notebook.id
        self.library = library
        initialPageCount = notebook.pageCount
        initialPageSize = notebook.pageSize
        initialTheme = notebook.theme
        state = EditorState(startsFocused: startsFocused)
        isCompanion = false
        wireState()
    }

    /// A second view of `owner`'s notebook (split view, #175): same document and history, its own canvas.
    /// It opens once the owner has.
    init(companionOf owner: NotebookSession) {
        notebookID = owner.notebookID
        library = owner.library
        initialPageCount = max(owner.host.layout.pageCount, owner.initialPageCount)
        initialPageSize = owner.host.layout.pageSize == .zero ? owner.initialPageSize : owner.host.layout.pageSize
        initialTheme = owner.initialTheme
        state = EditorState(edits: owner.state.edits)
        state.keepsExactColors = owner.state.keepsExactColors
        isCompanion = true
        self.owner = owner
        wireState()
    }

    private func wireState() {
        state.onSelectionAction = { [weak self] in self?.performSelectionAction($0) }
        state.onInsertPhoto = { [weak self] in self?.insertPhoto($0) }
        state.onKeepsExactColors = { [weak self] in self?.setKeepsExactColors($0) }
        state.onExportPDF = { [weak self] selection, asShown, progress in
            guard let self else { throw CancellationError() }
            return try await exportPDF(selection, asShown: asShown, progress: progress)
        }
        installPages()
    }

    var engine: any InkEngine {
        host.engine
    }

    // MARK: Open / close

    /// Opens the package (manifest only), lays out every page, then lets the page window load page 1,
    /// pages 2–3 and the rest of the window, in that order. A companion opens on its owner's store. Calls
    /// after the first wait for it.
    func open() async {
        if let opening {
            return await opening.value
        }
        let task = Task { @MainActor in
            if let owner {
                await openCompanion(of: owner)
            } else {
                await openDocument()
            }
        }
        opening = task
        await task.value
    }

    private func openDocument() async {
        guard store == nil, !isClosed else { return }
        _ = host
        holdsPackage = true
        Self.writerOpened(notebookID)
        await Self.closing[notebookID]?.value
        do {
            let url = try await library.documentURL(for: notebookID)
            let options = DocumentStore.Options { [weak self] event in
                guard case .checkpointed = event else { return }
                Task { @MainActor in await self?.didCheckpoint() }
            }
            let store = try await Task.detached(priority: .userInitiated) { try DocumentStore(opening: url, options: options) }.value
            guard !isClosed else { return }
            let manifest = await store.manifest
            await installArtwork(from: store)
            self.store = store
            let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
            let residency = PageResidency(store: store, engine: engine, pageSize: manifest.notebook.pageSize, pages: pages)
            residency.onPageLoaded = { [weak self] id in self?.pageLoaded(id) }
            residency.onPageEvicted = { [weak self] id in self?.flushThumbnail(id) }
            self.residency = residency
            thumbnails = makeThumbnailService(package: url)
            syncPagesModel(pages)
            engine.setTheme(manifest.notebook.theme)
            if manifest.notebook.keepsExactColors {
                state.keepsExactColors = true
                applyPalette(keepsExactColors: true)
            }
            showPages(pages.map(\.id), of: manifest.notebook)
            if let window = host.pageWindow {
                residency.update(window)
            }
            let edits = makeEdits(store: store, residency: residency)
            self.edits = edits
            selection = SelectionMachine(edits: edits, display: self)
            state.onUndo = { [weak self] in self?.edits?.undo() }
            state.onRedo = { [weak self] in self?.edits?.redo() }
        } catch {
            let id = notebookID
            Self.log.error("open \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            OpenTrace.cancel()
        }
    }

    /// The notebook's edit pipeline: its mirror is this residency, followed by every companion's.
    private func makeEdits(store: DocumentStore, residency: PageResidency) -> EditPipeline {
        let mirror = ResidencyMirror(residency: residency) { [weak self] in
            self?.companions.compactMap(\.residency) ?? []
        } onPagesChanged: { [weak self] in
            guard let self else { return }
            await refreshPages()
            for companion in companions {
                await companion.refreshPages()
            }
        }
        let edits = EditPipeline(store: store, mirror: mirror, history: state.edits, undoManager: host.editUndoManager)
        edits.onPageEdited = { [weak self] page in self?.thumbnailChanged(page) }
        edits.onHistoryWillApply = { [weak self] in
            guard let self else { return }
            for view in views {
                view.clearSelection()
            }
        }
        edits.onHistoryApplied = { [weak self] pages in self?.reveal(pages) }
        edits.addsPagesAutomatically = addsPagesAutomatically
        return edits
    }

    /// Checkpoints every dirty page and renders pending thumbnails (scene left the foreground).
    func flush() {
        guard !isCompanion else { return }
        if store != nil {
            savePosition()
        }
        edits?.run("flush") { [store, thumbnails] in
            try await store?.flush()
            await thumbnails?.flush()
        }
    }

    /// The editor went away: stop input, finish queued edits, checkpoint, update the library entry.
    func close() {
        guard !isClosed else { return }
        if isCompanion {
            return closeCompanion()
        }
        if store != nil {
            savePosition()
        }
        isClosed = true
        engine.delegate = nil
        host.delegate = nil
        inkExtentLookup?.cancel()
        widenSettle?.cancel()
        residency?.close()
        thumbnailRegeneration?.cancel()
        thumbnailFill?.cancel()
        edits?.close()
        let (edits, store, thumbnails, library, id, holds) = (edits, store, thumbnails, library, notebookID, holdsPackage)
        holdsPackage = false
        let task = Task { @MainActor in
            await edits?.drain()
            guard let store else { return }
            do {
                try await store.flush()
                // Cover before the library entry refreshes, so the index sees `cover.heic`.
                await thumbnails?.flush()
                await library.documentDidSave(store.manifest)
            } catch {
                Self.log.error("close flush failed: \(String(describing: error), privacy: .public)")
            }
        }
        Self.closing[id] = task
        Task { @MainActor in
            await task.value
            if Self.closing[id] == task {
                Self.closing[id] = nil
            }
            if holds {
                Self.writerClosed(id)
            }
        }
    }

    // MARK: Pages

    func pageLoaded(_ id: PageID) {
        ensureThumbnails(id)
        guard awaitingFirstPage, residency?.isVisible(id) == true else { return }
        awaitingFirstPage = false
        // The engine draws the snapshot on its next vsync: end `notebook.open` one display frame later.
        FrameAfter.next { OpenTrace.end() }
    }

    private func didCheckpoint() async {
        guard let store, !isClosed else { return }
        await library.documentDidSave(store.manifest)
    }

    // MARK: Factory

    private func makeHost() -> CanvasHostView {
        let palette = DesignSystemInkPalette()
        // PencilKit is the ink engine (spike #16, ARCHITECTURE.md §3); the Metal engine stays unwired.
        let engine = PencilKitInkEngine(palette: palette)
        engine.crossfadeDuration = Tokens.Motion.thumbnailCrossfadeDuration
        engine.setTheme(initialTheme)
        installPageImages(on: engine)
        let host = CanvasHostView(engine: engine)
        // Paper for every page from the first frame; real page IDs replace these when the manifest is read.
        host.layout = PageLayout(
            pageIDs: (0 ..< initialPageCount).map { _ in PageID() }, pageSize: initialPageSize, footer: CanvasHostView.footerHeight
        )
        host.accessibilityPageValue = { [weak self] in self?.currentPageDescription() }
        installAccessibilityActions(on: host)
        engine.delegate = self
        host.delegate = self
        installSelection(on: host, engine: engine, theme: initialTheme)
        installWidening(on: host, theme: initialTheme)
        return host
    }

    /// "12 strokes" for the page under the indicator (VoiceOver, UI tests).
    private func currentPageDescription() -> String? {
        let index = host.state.currentPage
        guard let residency, residency.pageIDs.indices.contains(index), let page = residency.page(residency.pageIDs[index]) else {
            return nil
        }
        return page.strokes.count == 1 ? "1 stroke" : "\(page.strokes.count) strokes"
    }
}

extension NotebookSession {
    /// Waits for every closing notebook's last checkpoint (sync after leaving the editor, #225).
    static func closingFinished() async {
        for task in closing.values {
            await task.value
        }
    }

    /// Notebooks an editor writes, in every window: from opening the package until the close's last
    /// checkpoint landed. Sync defers incoming page changes for them (#225).
    static var openNotebooks: Set<NotebookID> {
        Set(writers.keys)
    }

    /// Called whenever ``openNotebooks`` changes (``SyncModel``).
    static var openNotebooksDidChange: ((Set<NotebookID>) -> Void)?

    /// Writers per notebook (normally 0 or 1; a reopen can overlap the previous close).
    private static var writers: [NotebookID: Int] = [:]

    private static func writerOpened(_ id: NotebookID) {
        writers[id, default: 0] += 1
        openNotebooksDidChange?(openNotebooks)
    }

    private static func writerClosed(_ id: NotebookID) {
        writers[id, default: 1] -= 1
        if writers[id] == 0 {
            writers[id] = nil
        }
        openNotebooksDidChange?(openNotebooks)
    }
}

/// Reading position: scroll and zoom per notebook, on this device.
extension NotebookSession {
    /// Scroll and zoom per notebook, on this device, so a notebook reopens where it was left.
    private var positionKey: String {
        "readingPosition.\(notebookID.uuid.uuidString)"
    }

    /// The notebook's real pages, at `position` (default: where it was left).
    func showPages(_ ids: [PageID], of notebook: Notebook, at position: ReadingPosition? = nil) {
        host.pageExtension = PageExtension(notebook: notebook)
        host.layout = pageLayout(ids, pageSize: notebook.pageSize)
        (position ?? savedPosition()).map(host.restore)
    }

    private func savedPosition(defaults: UserDefaults = .standard) -> ReadingPosition? {
        defaults.data(forKey: positionKey).flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
    }

    private func savePosition(defaults: UserDefaults = .standard) {
        guard let position = host.readingPosition, let data = try? JSONEncoder().encode(position) else { return }
        defaults.set(data, forKey: positionKey)
    }
}
