import Canvas
import CoreGraphics
import enum DesignSystem.Tokens
import Document
import Editing
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
@MainActor
final class NotebookSession {
    /// The canvas host (and through it the engine), created on first use so building an `EditorScreen`
    /// value stays cheap.
    private(set) lazy var host: CanvasHostView = makeHost()
    /// Chrome state and the notebook's history.
    let state: EditorState
    let notebookID: NotebookID

    let library: any LibraryModel
    private let initialPageCount: Int
    private let initialPageSize: CGSize
    private var initialTheme: PaperTheme
    private(set) var store: DocumentStore?
    /// Imported PDF pages by page ID (#119): the engine draws them under the ink, export flattens onto them.
    var artwork: [PageID: any PageArtwork] = [:]
    /// Where artwork sits on widened pages; follows the manifest (``refreshPages()``).
    let artworkPlacement = ArtworkPlacement()
    private(set) var residency: PageResidency?
    /// Page thumbs + cover (`+Thumbnails`, §5.5): fed on every accepted edit, flushed with the store.
    private(set) var thumbnails: ThumbnailService?
    var thumbnailRegeneration: Task<Void, Never>?
    /// The one path for changes to the notebook (strokes, erasing, selection, pages, undo); set by ``open()``.
    private(set) var edits: EditPipeline?
    /// The toolbar's current tool (``setTool(_:allowsFingerDrawing:)``); erasing reads its mode and size.
    private var tool = ActiveTool.ink(.ballpoint, color: .primary, width: 2)
    private(set) var isClosed = false
    private var awaitingFirstPage = true
    var awaitingFirstSharp = true
    /// Lasso selection (`+Selection`); set by ``open()``.
    private(set) var selection: SelectionMachine?
    let selectionOverlay = SelectionOverlayView()

    private(set) static var closing: [NotebookID: Task<Void, Never>] = [:]
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "editor")

    init(notebook: NotebookSummary, library: any LibraryModel, startsFocused: Bool = false) {
        notebookID = notebook.id
        self.library = library
        initialPageCount = notebook.pageCount
        initialPageSize = notebook.pageSize
        initialTheme = notebook.theme
        state = EditorState(startsFocused: startsFocused)
        state.onSelectionAction = { [weak self] in self?.performSelectionAction($0) }
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
    /// pages 2–3 and the rest of the window, in that order.
    func open() async {
        guard store == nil, !isClosed else { return }
        _ = host
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
            let residency = PageResidency(store: store, engine: engine, pageSize: manifest.notebook.extendedPageSize, pages: pages)
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
            host.layout = pageLayout(manifest)
            if let window = host.pageWindow {
                residency.update(window)
            }
            let edits = EditPipeline(
                store: store,
                mirror: ResidencyMirror(residency: residency) { [weak self] in await self?.refreshPages() },
                history: state.edits,
                undoManager: host.editUndoManager
            )
            edits.onPageEdited = { [weak self] page in self?.thumbnailChanged(page) }
            edits.onHistoryWillApply = { [weak self] in self?.clearSelection() }
            edits.onHistoryApplied = { [weak self] pages in self?.reveal(pages) }
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

    /// Checkpoints every dirty page and renders pending thumbnails (scene left the foreground).
    func flush() {
        edits?.run("flush") { [store, thumbnails] in
            try await store?.flush()
            await thumbnails?.flush()
        }
    }

    /// The editor went away: stop input, finish queued edits, checkpoint, update the library entry.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        engine.delegate = nil
        host.delegate = nil
        residency?.close()
        thumbnailRegeneration?.cancel()
        edits?.close()
        let (edits, store, thumbnails, library, id) = (edits, store, thumbnails, library, notebookID)
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
        }
    }

    // MARK: Settings

    func setTool(_ tool: ActiveTool, allowsFingerDrawing: Bool) {
        if tool != .lasso {
            clearSelection()
        }
        self.tool = tool
        engine.setTool(tool.configuration(allowsFingerDrawing: allowsFingerDrawing))
        host.allowsFingerDrawing = allowsFingerDrawing
    }

    /// Paper color and pattern from the ⋯ popover: the engine re-themes at once; the pattern becomes the
    /// template of every page and of new pages.
    func setPaper(theme: PaperTheme, style: PaperStyle) {
        engine.setTheme(theme)
        tintSelection(for: theme)
        initialTheme = theme
        edits?.run("paper") { [weak self] in
            guard let self, let store, let residency else { return }
            let manifest = await store.manifest
            guard manifest.notebook.theme != theme || manifest.notebook.paper != style else { return }
            try await store.updateNotebook { notebook in
                notebook.theme = theme
                notebook.paper = style
            }
            if manifest.notebook.paper != style {
                try await store.setTemplate(style.defaultTemplate)
                residency.setTemplate(style.defaultTemplate, for: residency.pageIDs)
            }
            await library.documentDidSave(store.manifest)
            regenerateThumbnails()
        }
    }

    // MARK: History

    /// Undo/redo changed `ids`: scrolls to the first page `ids` touched if none of them is on screen.
    func reveal(_ ids: [PageID]) {
        guard let residency, residency.window != nil, !ids.contains(where: residency.isVisible),
              let first = ids.lazy.compactMap(residency.pageIDs.firstIndex(of:)).first else { return }
        host.scrollToPage(first, animated: true)
    }

    // MARK: Pages

    private func pageLoaded(_ id: PageID) {
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

// MARK: - Engine

extension NotebookSession: InkEngineDelegate {
    func engine(_: any InkEngine, didCommit stroke: Stroke, to page: PageID) {
        edits?.commitStroke(stroke, to: page)
    }

    /// Each batch is applied at once (stroke mode removes the strokes it touched, partial mode splits them,
    /// highlighter included); at gesture end ``EditPipeline`` collapses the batches into one undo step.
    func engine(_: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID) {
        guard case let .eraser(eraser) = tool else { return }
        edits?.erase(samples, on: page, diameter: eraser.width, mode: eraser.mode)
    }

    /// A finished lasso: strokes with ≥ 50 % of their samples inside become the selection (`+Selection`).
    func engine(_: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID) {
        selection?.lassoClosed(path, on: page)
    }

    func engineDidBeginStroke(_: any InkEngine) {
        clearSelection()
        state.strokeBegan()
        if !host.isFirstResponder {
            host.becomeFirstResponder()
        }
        edits?.beginGesture(erasing: tool.isEraser)
    }
}

// MARK: - Canvas

extension NotebookSession: CanvasHostViewDelegate {
    func canvasHost(_: CanvasHostView, didChange window: PageWindow) {
        residency?.update(window)
        if let selected = selection?.selection, residency?.isVisible(selected.pageID) != true {
            clearSelection()
        }
    }

    func canvasHostWillBeginNavigating(_: CanvasHostView) {
        state.exitFocus()
    }

    func canvasHostDidRequestNewPage(_: CanvasHostView) {
        insertPage(after: nil, template: nil)
    }

    func canvasHostDidLiftAllTouches(_: CanvasHostView) {
        state.strokeEnded()
        edits?.endGesture()
    }

    func canvasHost(_: CanvasHostView, didRequestPageExtension pageExtension: PageExtension) {
        setPageExtension(pageExtension)
    }

    func canvasHostInkSpan(_: CanvasHostView) async -> ClosedRange<CGFloat>? {
        await inkSpan()
    }
}
