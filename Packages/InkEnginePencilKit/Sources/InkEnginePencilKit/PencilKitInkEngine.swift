import InkEngine
import InkModel
import os
import PencilKit
import UIKit

/// `InkEngine` backed by PencilKit: the shipping ink engine (spike #16, ARCHITECTURE.md §3).
///
/// One `PKCanvasView` covers the *active* page (the one last touched, else the one nearest the
/// viewport center), clipped to the visible rect and zoomed with the viewport. Other visible pages
/// show a raster of their ink (`PKDrawing.image`, rendered off main, recent ones kept in an
/// ``InkRasterCache`` that empties on memory warnings). Pens draw through PencilKit; eraser and lasso
/// input goes through the shared ``InkEngine/InkInputView`` pipeline and is reported, never applied.
///
/// The canvas starts each page from the document snapshot. A finished PencilKit stroke is reported
/// via `didCommit` and kept on the canvas as pending until the document echoes it back through
/// ``apply(_:to:)`` or ``setPages(_:)``; any other change rebuilds the canvas from the snapshot.
/// PencilKit's own undo is disabled (undo goes through `Tools`).
///
/// Ink colors are resolved by the ``InkEngine/InkPalette`` and the canvas is pinned to light
/// appearance, so PencilKit never applies its own dark-mode inversion.
@MainActor
public final class PencilKitInkEngine: NSObject, InkEngine {
    public var view: UIView {
        host
    }

    public weak var delegate: (any InkEngineDelegate)?

    /// Longest side of an inactive page's ink raster (px). Bounds memory at high zoom (softer ink).
    public var maximumRasterDimension: CGFloat = 4096

    let palette: any InkPalette
    let host = HostView()
    let pagesView = UIView()
    let canvas = AdapterCanvasView()
    let input = InkInputView()
    /// Ink rasters of recently shown inactive pages.
    let rasters = InkRasterCache()

    private(set) var viewport = Viewport.empty
    private(set) var snapshots: [PageID: PageSnapshot] = [:]
    private(set) var tool = ToolConfiguration.default
    private(set) var theme = PaperTheme.white
    private(set) var activePage: PageID?
    /// Stroke IDs parallel to `canvas.drawing.strokes`.
    private(set) var canvasIDs: [StrokeID] = []
    /// Strokes reported via `didCommit` but not yet in the page snapshot, per page, in draw order.
    private(set) var pending: [PageID: [(id: StrokeID, pk: PKStroke)]] = [:]
    private(set) var hasSeenPencil = false
    /// Whether the canvas has rendered the active page since it moved there; until then that page's
    /// raster stays visible underneath, so the page never shows blank paper.
    private(set) var canvasHasRendered = false
    private var activation = 0

    var pageViews: [PageID: PageLayerView] = [:]
    private var isSettingDrawing = false
    private var isUsingTool = false
    private var needsCanvasRebuild = false
    private var eraserProgress: (touch: TouchID, emitted: Int)?
    /// Full canvas rebuilds so far (tests check the commit echo path doesn't rebuild).
    private(set) var rebuildCount = 0
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "ink.pencilkit")

    /// Creates the engine. `palette` resolves paper and ink colors (the app adapts `DesignSystem`).
    public init(palette: any InkPalette) {
        self.palette = palette
        super.init()
        host.clipsToBounds = true
        host.backgroundColor = .clear
        host.onHitTest = { [weak self] point in self?.willReceiveTouch(at: point) }
        pagesView.isUserInteractionEnabled = false
        pagesView.frame = host.bounds
        pagesView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(pagesView)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.bouncesZoom = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        // Zoom is pinned to the viewport's (``layoutCanvas()`` sets min = max = zoom), so the canvas has
        // no pinch of its own and a pinch over it zooms the host scroll view (the whole page).
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 1
        canvas.isHidden = true
        canvas.delegate = self
        canvas.onPencilTouch = { [weak self] in self?.pencilSeen() }
        host.addSubview(canvas)

        input.frame = host.bounds
        input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        input.delegate = self
        host.addSubview(input)
        applyTool()
        NotificationCenter.default.addObserver(
            self, selector: #selector(didReceiveMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    @objc private func didReceiveMemoryWarning() {
        rasters.removeAll()
    }

    // MARK: InkEngine

    public func setViewport(_ viewport: Viewport) {
        self.viewport = viewport
        if activePage.flatMap(viewport.page) == nil, !isUsingTool {
            activate(viewport.centerPage?.id)
        }
        layoutPages()
        layoutCanvas()
    }

    public func setPages(_ pages: [PageSnapshot]) {
        let old = snapshots
        snapshots = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (id, snapshot) in snapshots where old[id] != snapshot {
            let ids = Set(snapshot.strokes.map(\.id))
            pending[id]?.removeAll { ids.contains($0.id) }
            // Only appended strokes (echoed commits) keep the canvas; anything else rebuilds it.
            let appendedOnly = old[id].map { snapshot.strokes.starts(with: $0.strokes) } ?? false
            contentChanged(id, rebuild: !appendedOnly)
        }
        if let active = activePage, old[active] != nil, snapshots[active] == nil {
            rebuildCanvas()
        }
        layoutPages()
        layoutCanvas()
    }

    public func setTool(_ tool: ToolConfiguration) {
        if tool.tool != self.tool.tool {
            input.cancelActiveStroke()
        }
        self.tool = tool
        applyTool()
    }

    public func setTheme(_ theme: PaperTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        applyTool()
        rebuildCanvas()
        layoutPages()
    }

    public func apply(_ edit: PageEdit, to page: PageID) {
        guard let snapshot = snapshots[page] else { return }
        do {
            snapshots[page] = try snapshot.applying(edit)
        } catch {
            Self.log.error("apply failed on \(page, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        var echoedOnly = false
        if case let .add(placed) = edit, let waiting = pending[page] {
            let ids = Set(placed.map(\.stroke.id))
            echoedOnly = ids.isSubset(of: Set(waiting.map(\.id)))
            pending[page] = waiting.filter { !ids.contains($0.id) }
        }
        contentChanged(page, rebuild: !echoedOnly)
    }

    public func invalidate(_: CGRect, in page: PageID) {
        // The active canvas holds vectors; inactive pages re-rasterize (keeping the old raster meanwhile).
        if page != activePage {
            pageViews[page]?.invalidateInk()
            layoutPages()
        }
    }

    /// Thumbnails and export fallback: paper + template + ink, drawn by PencilKit from the stored strokes.
    public func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0, page.size.width > 0, page.size.height > 0 else { return nil }
        let job = RenderJob(page: page, palette: palette, theme: theme)
        return await Task.detached(priority: .userInitiated) { job.page(size: size, scale: scale) }.value
    }

    // MARK: Active page

    /// Pen-down hit test: makes the page under a touch active so the canvas is there to receive it.
    func willReceiveTouch(at point: CGPoint) {
        guard tool.penKind != nil, !isUsingTool, let page = viewport.page(at: point), page.id != activePage else { return }
        activate(page.id)
    }

    func activate(_ id: PageID?) {
        guard id != activePage else { return }
        absorbCanvasStrokes()
        if let previous = activePage {
            coverPageLeavingCanvas(previous)
        }
        activePage = id
        canvasHasRendered = false
        activation += 1
        rebuildCanvas()
        layoutPages()
        layoutCanvas()
        // `canvasViewDidFinishRendering` normally comes within a few frames; don't wait on it forever.
        let current = activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, activation == current else { return }
            canvasDidRender()
        }
    }

    /// The canvas is leaving `page`: until its raster is ready, a snapshot of what the canvas showed
    /// stands in, so the ink doesn't blink out (or show a stale raster) as the canvas moves on.
    private func coverPageLeavingCanvas(_ page: PageID) {
        guard let view = pageViews[page], canvasHasRendered, !canvas.isHidden, !canvas.drawing.strokes.isEmpty,
              let snapshot = canvas.snapshotView(afterScreenUpdates: false) else { return }
        let zoom = max(viewport.zoomScale, 0.01)
        let local = canvas.frame.offsetBy(dx: -view.frame.minX, dy: -view.frame.minY)
        let pageRect = CGRect(x: local.minX / zoom, y: local.minY / zoom, width: local.width / zoom, height: local.height / zoom)
        view.setPlaceholder(snapshot, pageRect: pageRect)
    }

    /// The canvas shows the active page: its raster can hide.
    private func canvasDidRender() {
        guard !canvasHasRendered else { return }
        canvasHasRendered = true
        if let page = activePage {
            pageViews[page]?.showsInk = false
        }
    }

    private func contentChanged(_ page: PageID, rebuild: Bool) {
        if page == activePage {
            let desired = (snapshots[page]?.strokes.map(\.id) ?? []) + (pending[page] ?? []).map(\.id)
            if rebuild || desired != canvasIDs {
                rebuildCanvas()
            }
        } else {
            layoutPages()
        }
    }

    /// Reports strokes PencilKit added since the last sync.
    private func absorbCanvasStrokes() {
        guard let page = activePage else { return }
        let strokes = canvas.drawing.strokes
        guard strokes.count > canvasIDs.count else {
            if strokes.count < canvasIDs.count {
                rebuildCanvas() // something outside the seam removed strokes; restore the snapshot
            }
            return
        }
        let kind = tool.penKind ?? .ballpoint
        for pk in strokes[canvasIDs.count...] {
            let stroke = PencilKitConversion.stroke(from: pk, tool: kind, color: tool.color, width: tool.width)
            canvasIDs.append(stroke.id)
            pending[page, default: []].append((stroke.id, pk))
            delegate?.engine(self, didCommit: stroke, to: page)
        }
    }

    /// Replaces the canvas drawing with the active page's snapshot plus pending strokes.
    private func rebuildCanvas() {
        guard !isUsingTool else {
            needsCanvasRebuild = true
            return
        }
        needsCanvasRebuild = false
        rebuildCount += 1
        if canvas.drawing.strokes.count > canvasIDs.count {
            absorbCanvasStrokes()
        }
        var strokes: [PKStroke] = []
        var ids: [StrokeID] = []
        if let page = activePage, let snapshot = snapshots[page] {
            for stroke in snapshot.strokes {
                strokes.append(PencilKitConversion.pkStroke(from: stroke, color: uiColor(stroke.color)))
                ids.append(stroke.id)
            }
            for entry in pending[page] ?? [] {
                strokes.append(entry.pk)
                ids.append(entry.id)
            }
        }
        isSettingDrawing = true
        canvas.drawing = PKDrawing(strokes: strokes)
        isSettingDrawing = false
        canvasIDs = ids
    }

    // MARK: Tool

    private func applyTool() {
        canvas.drawingPolicy = tool.allowsFingerDrawing && !hasSeenPencil ? .anyInput : .pencilOnly
        input.allowsFingerDrawing = tool.allowsFingerDrawing
        switch tool.tool {
        case let .pen(kind):
            canvas.tool = PencilKitConversion.inkingTool(kind, color: uiColor(tool.color), width: tool.width)
            canvas.isUserInteractionEnabled = true
            input.isHidden = true
        case .eraser, .lasso:
            canvas.isUserInteractionEnabled = false
            input.isHidden = false
        }
    }

    private func pencilSeen() {
        guard !hasSeenPencil else { return }
        hasSeenPencil = true
        applyTool()
    }

    func uiColor(_ color: InkColor) -> UIColor {
        UIColor(palette.ink(color, on: theme))
    }
}

// MARK: - PKCanvasViewDelegate

extension PencilKitInkEngine: PKCanvasViewDelegate {
    public func canvasViewDidBeginUsingTool(_: PKCanvasView) {
        isUsingTool = true
        delegate?.engineDidBeginStroke(self)
    }

    public func canvasViewDidEndUsingTool(_: PKCanvasView) {
        isUsingTool = false
        absorbCanvasStrokes()
        if needsCanvasRebuild {
            rebuildCanvas()
        }
    }

    public func canvasViewDrawingDidChange(_: PKCanvasView) {
        guard !isSettingDrawing else { return }
        absorbCanvasStrokes()
    }

    public func canvasViewDidFinishRendering(_: PKCanvasView) {
        canvasDidRender()
    }
}

// MARK: - Eraser / lasso input

extension PencilKitInkEngine: InkInputViewDelegate {
    public func inkInputView(_: InkInputView, targetAt point: CGPoint) -> InkInputTarget? {
        guard let page = viewport.page(at: point) else { return nil }
        return InkInputTarget(page: page.id, viewToPage: viewport.viewToPage(page))
    }

    public func inkInputView(_: InkInputView, didProduce event: InkInputTracker.Event) {
        switch event {
        case let .began(stroke):
            if stroke.device == .pencil {
                pencilSeen()
            }
            eraserProgress = (stroke.touch, 0)
            delegate?.engineDidBeginStroke(self)
            emitEraser(stroke)
        case let .updated(stroke):
            emitEraser(stroke)
        case let .ended(stroke):
            emitEraser(stroke)
            if tool.tool == .lasso {
                delegate?.engine(self, didReceiveLasso: stroke.samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }, to: stroke.page)
            }
        case .cancelled:
            break
        }
    }

    private func emitEraser(_ stroke: LiveStroke) {
        guard tool.tool == .eraser, let progress = eraserProgress, progress.touch == stroke.touch,
              stroke.samples.count > progress.emitted else { return }
        eraserProgress = (stroke.touch, stroke.samples.count)
        delegate?.engine(self, didReceiveEraser: Array(stroke.samples[progress.emitted...]), to: stroke.page)
    }
}
