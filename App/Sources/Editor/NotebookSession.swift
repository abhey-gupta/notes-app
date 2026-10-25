import Canvas
import Document
import InkEngine
import InkEnginePencilKit
import InkModel
import os
import Perf
import QuartzCore
import Tools

/// One open notebook in the editor: the wiring between canvas, engine, document and history
/// (ARCHITECTURE.md §3.1, §4.4, §6, §8).
///
/// ```
/// Pencil ─▶ engine ─didCommit/eraser─▶ session ─PageEdit─▶ DocumentStore.apply (journaled)
///                                          │                     │
///                                          │◀────── accepted ────┘
///                                          ├─▶ PageResidency.didApply ─▶ mirror + engine.apply (echo)
///                                          └─▶ EditStack.record ─▶ UndoManagerBridge (⌘Z, 3-finger)
/// undo/redo ─▶ EditStack ─inverse─▶ same path (store first, then mirror + engine)
/// scroll ─▶ CanvasHostView ─PageWindow─▶ PageResidency ─▶ store.page / store.evict, engine.setPages
/// ```
///
/// Edits run one at a time in arrival order on a main-actor queue (``enqueue(_:_:)``): each one reads the
/// page mirror, waits for the store to journal it, then updates mirror, engine and history, so the next
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
    private var initialTheme: PaperTheme
    private(set) var store: DocumentStore?
    private(set) var residency: PageResidency?
    private var bridge: UndoManagerBridge?
    private var tool = ToolConfiguration.default
    private var eraser = EraserRun()
    /// Stroke or partial erase (`ToolState.eraser.mode`).
    var eraserMode: EraserSettings.Mode = .stroke
    private var queue: Task<Void, Never>?
    private var isClosed = false
    private var awaitingFirstPage = true
    /// Lasso selection (`+Selection`).
    var selection: LassoSelection?
    var isBakingSelection = false
    var selectionDragCorner: LassoSelection.Corner?
    let selectionOverlay = SelectionOverlayView()

    private static var closing: [NotebookID: Task<Void, Never>] = [:]
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "editor")

    init(notebook: NotebookSummary, library: any LibraryModel, startsFocused: Bool = false) {
        notebookID = notebook.id
        self.library = library
        initialPageCount = notebook.pageCount
        initialTheme = notebook.theme
        state = EditorState(startsFocused: startsFocused)
        state.onSelectionAction = { [weak self] in self?.performSelectionAction($0) }
        state.onKeepsExactColors = { [weak self] in self?.setKeepsExactColors($0) }
        state.onExportPDF = { [weak self] selection, asShown, progress in
            guard let self else { throw CancellationError() }
            return try await exportPDF(selection, asShown: asShown, progress: progress)
        }
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
            self.store = store
            let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
            let residency = PageResidency(store: store, engine: engine, pageSize: manifest.notebook.pageSize, pages: pages)
            residency.onPageLoaded = { [weak self] id in self?.pageLoaded(id) }
            self.residency = residency
            engine.setTheme(manifest.notebook.theme)
            if manifest.notebook.keepsExactColors {
                state.keepsExactColors = true
                applyPalette(keepsExactColors: true)
            }
            host.layout = PageLayout(pageIDs: pages.map(\.id), pageSize: manifest.notebook.pageSize, footer: CanvasHostView.footerHeight)
            if let window = host.pageWindow {
                residency.update(window)
            }
            bridge = UndoManagerBridge(stack: state.edits, undoManager: host.editUndoManager) { [weak self] entry in
                self?.applyHistory(entry)
            }
            state.onUndo = { [weak self] in self?.bridge?.undo() }
            state.onRedo = { [weak self] in self?.bridge?.redo() }
        } catch {
            let id = notebookID
            Self.log.error("open \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            OpenTrace.end()
        }
    }

    /// Checkpoints every dirty page (scene left the foreground).
    func flush() {
        enqueue("flush") { [store] in try await store?.flush() }
    }

    /// The editor went away: stop input, finish queued edits, checkpoint, update the library entry.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        engine.delegate = nil
        host.delegate = nil
        residency?.close()
        bridge?.detach()
        state.edits.removeAll()
        let (queue, store, library, id) = (queue, store, library, notebookID)
        let task = Task { @MainActor in
            await queue?.value
            guard let store else { return }
            do {
                try await store.flush()
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

    func setTool(_ configuration: ToolConfiguration) {
        if configuration.tool != .lasso {
            clearSelection()
        }
        tool = configuration
        engine.setTool(configuration)
        host.allowsFingerDrawing = configuration.allowsFingerDrawing
    }

    /// Paper color and pattern from the title menu: the engine re-themes at once; the pattern becomes the
    /// template of every page and of new pages.
    func setPaper(theme: PaperTheme, style: PaperStyle) {
        engine.setTheme(theme)
        tintSelection(for: theme)
        initialTheme = theme
        enqueue("paper") { [weak self] in
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
        }
    }

    // MARK: Edits

    /// Runs `operation` after every earlier one, logging (and recovering from) failures.
    func enqueue(_ name: StaticString, _ operation: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            do {
                try await operation()
            } catch {
                Self.log.error("\(name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Applies `edit` to the store, then mirror + engine; reloads the page if the store refused it.
    func commit(_ edit: PageEdit, to page: PageID) async throws {
        guard let store, let residency else { return }
        do {
            try await store.apply(edit, to: page)
        } catch {
            await residency.reload(page)
            throw error
        }
        residency.didApply(edit, to: page)
    }

    private func applyHistory(_ entry: EditEntry) {
        clearSelection()
        enqueue("history") { [weak self] in
            guard let self, let residency else { return }
            eraser.reset() // the page may change under an eraser gesture in progress
            do {
                for step in entry.steps {
                    _ = try await residency.ensureLoaded(step.pageID)
                    try await commit(step.edit, to: step.pageID)
                }
            } catch {
                // The history no longer matches the document.
                state.edits.removeAll()
                throw error
            }
            reveal(entry.pageIDs)
        }
    }

    /// Scrolls to the first page `ids` touched if none of them is on screen.
    private func reveal(_ ids: [PageID]) {
        guard let window = host.pageWindow else { return }
        let indices = ids.compactMap(host.layout.index(of:))
        guard let first = indices.first, !indices.contains(where: { window.visible.contains($0) }) else { return }
        host.scrollToPage(first, animated: true)
    }

    // MARK: Pages

    private func pageLoaded(_ id: PageID) {
        guard awaitingFirstPage, let window = host.pageWindow,
              window.visible.contains(where: { host.layout.pageIDs[$0] == id }) else { return }
        awaitingFirstPage = false
        // The engine draws the snapshot on its next vsync: end `notebook.open` one display frame later.
        FrameAfter.next { OpenTrace.end() }
    }

    private func addPage() {
        enqueue("add page") { [weak self] in
            guard let self, let store, let residency else { return }
            try await store.insertPage(at: nil, template: nil)
            let manifest = await store.manifest
            let pages = manifest.pages.map { (id: $0.id, template: $0.template) }
            residency.setPages(pages)
            host.layout = PageLayout(pageIDs: pages.map(\.id), pageSize: manifest.notebook.pageSize, footer: CanvasHostView.footerHeight)
            if let window = host.pageWindow {
                residency.update(window)
            }
            host.scrollToPage(pages.count - 1, animated: true)
            library.documentDidSave(manifest)
        }
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
        engine.setTheme(initialTheme)
        let host = CanvasHostView(engine: engine)
        // Paper for every page from the first frame; real page IDs replace these when the manifest is read.
        host.layout = PageLayout(pageIDs: (0 ..< initialPageCount).map { _ in PageID() }, footer: CanvasHostView.footerHeight)
        host.accessibilityPageValue = { [weak self] in self?.currentPageDescription() }
        engine.delegate = self
        host.delegate = self
        installSelection(on: host, engine: engine, theme: initialTheme)
        return host
    }

    /// "12 strokes" for the page under the indicator (VoiceOver, UI tests).
    private func currentPageDescription() -> String? {
        let index = host.state.currentPage
        guard let residency, host.layout.pageIDs.indices.contains(index), let page = residency.page(host.layout.pageIDs[index]) else {
            return nil
        }
        return page.strokes.count == 1 ? "1 stroke" : "\(page.strokes.count) strokes"
    }
}

// MARK: - Engine

extension NotebookSession: InkEngineDelegate {
    func engine(_: any InkEngine, didCommit stroke: Stroke, to page: PageID) {
        enqueue("stroke") { [weak self] in
            guard let self, let residency else { return }
            let edit = try await residency.ensureLoaded(page).addEdit([stroke])
            try await commit(edit, to: page)
            state.edits.record(edit, on: page, actionName: "Stroke")
        }
    }

    /// Each batch is applied at once (stroke mode removes the strokes it touched, partial mode splits them,
    /// highlighter included); at gesture end ``EraserRun`` collapses the batches into one undo step.
    func engine(_: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID) {
        let (diameter, mode) = (tool.width, eraserMode)
        enqueue("erase") { [weak self] in
            guard let self, let residency else { return }
            let current = try await residency.ensureLoaded(page)
            guard let edit = try eraser.erase(samples, on: page, current: current, diameter: diameter, mode: mode) else { return }
            try await commit(edit, to: page)
            state.edits.record(edit, on: page, actionName: "Erase")
            eraser.accept()
        }
    }

    /// A finished lasso: strokes with ≥ 50 % of their samples inside become the selection (`+Selection`).
    func engine(_: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID) {
        select(lasso: path, on: page)
    }

    func engineDidBeginStroke(_: any InkEngine) {
        clearSelection()
        state.strokeBegan()
        if !host.isFirstResponder {
            host.becomeFirstResponder()
        }
        let isEraser = tool.tool == .eraser
        enqueue("gesture") { [weak self] in
            guard let self else { return }
            eraser.finish(in: state.edits)
            state.edits.endAllGroups()
            if isEraser {
                state.edits.beginGroup(actionName: "Erase")
            }
        }
    }
}

// MARK: - Canvas

extension NotebookSession: CanvasHostViewDelegate {
    func canvasHost(_: CanvasHostView, didChange window: PageWindow) {
        residency?.update(window)
        if let selection, !window.visible.contains(where: { host.layout.pageIDs[$0] == selection.pageID }) {
            clearSelection()
        }
    }

    func canvasHostWillBeginNavigating(_: CanvasHostView) {
        state.exitFocus()
    }

    func canvasHostDidRequestNewPage(_: CanvasHostView) {
        addPage()
    }

    func canvasHostDidLiftAllTouches(_: CanvasHostView) {
        state.strokeEnded()
        enqueue("gesture end") { [weak self] in
            guard let self else { return }
            eraser.finish(in: state.edits)
            state.edits.endAllGroups()
        }
    }
}

/// Runs a closure on the next display refresh (one-shot `CADisplayLink`).
@MainActor
private final class FrameAfter: NSObject {
    private var action: (() -> Void)?
    private var link: CADisplayLink?

    static func next(_ action: @escaping () -> Void) {
        let frame = FrameAfter()
        frame.action = action
        let link = CADisplayLink(target: frame, selector: #selector(tick))
        frame.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        action?()
        action = nil
    }
}
