import InkEngine
import InkModel
import os
import PencilKit
import UIKit

/// `InkEngine` backed by PencilKit: the shipping ink engine (spike #16, ARCHITECTURE.md §3).
///
/// The engine view is content-sized and sits inside the host's zoom view, so UIKit's one zoom transform
/// moves paper and ink together. Every visible page has a ``PageLayerView`` (paper, template, a raster
/// of its ink) and, from a small pool, a `PKCanvasView` covering its visible part (``PageCanvas``,
/// ``CanvasPlacement``); the raster shows through where no canvas has drawn yet. Rasters are
/// `PKDrawing.image`, rendered off main a few at a time nearest the viewport first (``RasterRenderQueue``),
/// kept per zoom bucket in an ``InkRasterCache`` that empties on memory warnings; while one renders the
/// page shows its nearest cached raster, its thumbnail or just paper (`+Images`, #70). Pens draw through
/// PencilKit (pens with pressure off through `+FlatPen`, #123); the highlighter draws its own bands as
/// shape layers beneath everything (`+Highlighter`, ``Highlight``, #120); eraser and lasso input goes
/// through the shared ``InkEngine/InkInputView`` pipeline and is reported, never applied.
///
/// A canvas starts its page from the document snapshot. A finished PencilKit stroke is reported via
/// `didCommit` and kept on the canvas as pending until the document echoes it back through
/// ``apply(_:to:)`` or ``setPages(_:)``; any other change rebuilds the canvas from the snapshot.
/// PencilKit's own undo is disabled (undo goes through `Tools`).
///
/// Ink colors are resolved by the ``InkEngine/InkPalette`` and the canvases are pinned to light
/// appearance, so PencilKit never applies its own dark-mode inversion.
@MainActor
public final class PencilKitInkEngine: NSObject, InkEngine {
    public var view: UIView {
        host
    }

    public weak var delegate: (any InkEngineDelegate)?

    /// Longest side of a page's ink raster (px). Bounds memory at high zoom (softer ink).
    public var maximumRasterDimension: CGFloat = 4096
    /// Canvases at once: the pages nearest the viewport center get one; others show their raster only.
    /// Each canvas is at most viewport-sized (its Metal layer too).
    public var maximumCanvases = 6
    /// `thumbs/<page>.heic` for a page, shown scaled up while its strokes load or its first raster
    /// renders (#43, #70). `nil`: the page shows flat paper meanwhile.
    public var thumbnailURL: ((PageID) -> URL?)?
    public var imageURL: ((ImageAssetID) -> URL?)?
    /// Imported artwork (a PDF page) per page, drawn as cached bitmaps under the template and ink (#119, #193).
    public var pageArtwork: ((PageID) -> (any PageArtwork)?)? {
        didSet {
            layoutPages()
        }
    }

    /// Thumbnail → raster crossfade, seconds (the app sets `Tokens.Motion.thumbnailCrossfadeDuration`).
    public var crossfadeDuration: TimeInterval = 0.12 {
        didSet {
            for view in pageViews.values {
                view.crossfadeDuration = crossfadeDuration
            }
        }
    }

    private(set) var palette: any InkPalette
    let host = HostView()
    let pagesView = UIView()
    /// The canvas pool: every `PKCanvasView` made so far, assigned to a page or free.
    private(set) var canvases: [PageCanvas] = []
    let input = InkInputView()
    /// Ink rasters of recently shown pages, per zoom bucket, and decoded thumbnails.
    let rasters = InkRasterCache()
    /// Decoded photos by asset (`+Photos`, #157).
    let photos = PhotoCache()
    /// Off-main raster renders, nearest the viewport first.
    let renderQueue = RasterRenderQueue()
    /// Imported artwork bitmaps, their cache and render queues (`+Artwork`, #193).
    let artworkPipeline = ArtworkPipeline()
    /// Thumbnails being decoded, and pages that have none on disk.
    var thumbnailLoads: Set<PageID> = []
    var thumbnailMisses: Set<PageID> = []
    /// Above the canvases: the live lasso path and lifted (lasso-dragged) strokes (`+Selection`).
    let selection = SelectionLayers()
    /// Laser pointer dot and trail, on the selection view (`+Laser`, #159).
    let laser = LaserPointer()
    /// Hold to snap: the drawing touch and the shape following it (`+ShapeSnap`, #165).
    let shapeSnap = ShapeSnap()
    /// Hold to erase: the touch held still and its eraser stroke (`+HoldErase`, #211).
    let holdErase = HoldErase()
    /// Ink running onto other pages while the Pencil is down (`+CrossPage`, #163).
    let crossPage = CrossPage()

    private(set) var viewport = Viewport.empty
    private(set) var snapshots: [PageID: PageSnapshot] = [:]
    private(set) var tool = ToolConfiguration.default
    private(set) var theme = PaperTheme.white
    /// The canvases' strokes as PencilKit strokes, converted off main by ``prepare(_:)`` or on first use.
    let strokeCache = PKStrokeCache()
    /// Strokes reported via `didCommit` but not yet in the page snapshot, per page, in draw order.
    var pending: [PageID: [PendingStroke]] = [:]
    var hasSeenPencil = false

    var pageViews: [PageID: PageLayerView] = [:]
    var isSettingDrawing = false
    var eraserProgress: EraserProgress?
    /// Full canvas rebuilds so far (tests check the commit echo path doesn't rebuild).
    private(set) var rebuildCount = 0
    private static let log = Logger(subsystem: "com.abhey.notespace", category: "ink.pencilkit")

    /// Creates the engine. `palette` resolves paper and ink colors (the app adapts `DesignSystem`).
    public init(palette: any InkPalette) {
        self.palette = palette
        super.init()
        host.backgroundColor = .clear
        pagesView.isUserInteractionEnabled = false
        pagesView.frame = host.bounds
        pagesView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(pagesView)
        setUpSelectionLayers()

        input.frame = host.bounds
        input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        input.delegate = self
        host.addSubview(input)
        setUpShapeSnap()
        setUpHoldErase()
        setUpCrossPage()
        applyTool()
        installHousekeeping()
    }

    // MARK: InkEngine

    public func setViewport(_ viewport: Viewport) {
        self.viewport = viewport
        layoutCanvases()
        layoutPages()
    }

    public func setPages(_ pages: [PageSnapshot]) {
        let old = snapshots
        snapshots = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        strokeCache.retain(snapshots.keys)
        for (id, snapshot) in snapshots where old[id] != snapshot {
            let ids = Set(snapshot.strokes.map(\.id))
            pending[id]?.removeAll { ids.contains($0.id) }
            // Only appended strokes (echoed commits) keep the canvas; anything else rebuilds it.
            let appendedOnly = old[id].map { snapshot.strokes.starts(with: $0.strokes) } ?? false
            contentChanged(id, rebuild: !appendedOnly)
            if let previous = old[id], !previous.isLoaded, snapshot.isLoaded, let canvas = canvas(for: id) {
                // The strokes arrived: the thumbnail stays whole until the canvas has drawn them.
                canvas.renderedRegion = nil
                capRenderWait(canvas)
            }
        }
        for canvas in canvases {
            if let page = canvas.page, old[page] != nil, snapshots[page] == nil {
                rebuildCanvas(canvas)
            }
        }
        layoutCanvases()
        layoutPages()
    }

    public func setTool(_ tool: ToolConfiguration) {
        if tool.tool != self.tool.tool {
            input.cancelActiveStroke()
        }
        cancelShapeSnap(unlessKeptBy: tool)
        cancelHoldErase(unlessKeptBy: tool)
        self.tool = tool
        applyTool()
        beginHoldErasingIfReady()
    }

    public func setPalette(_ palette: any InkPalette) {
        self.palette = palette
        strokeCache.removeAll()
        applyTool()
        for canvas in canvases where canvas.page != nil {
            rebuildCanvas(canvas)
        }
        layoutPages()
    }

    public func setTheme(_ theme: PaperTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        rasters.removeThumbnails() // they show the paper; the service regenerates them
        strokeCache.removeAll()
        thumbnailMisses = []
        applyTool()
        for canvas in canvases where canvas.page != nil {
            rebuildCanvas(canvas)
        }
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
        if edit.touchesImagesOnly {
            // Photos are the page views' own layers: nothing for the canvas to redo.
            layoutPages()
            return
        }
        var echoedOnly = false
        if case let .add(placed) = edit {
            let ids = Set(placed.map(\.stroke.id))
            let waiting = pending[page] ?? []
            // Echoed commits, or highlights (never on the canvas): the canvas already shows the rest.
            let waitingIDs = Set(waiting.map(\.id))
            echoedOnly = placed.allSatisfy { Highlight.isHighlight($0.stroke) || waitingIDs.contains($0.stroke.id) }
            pending[page] = waiting.filter { !ids.contains($0.id) }
        }
        contentChanged(page, rebuild: !echoedOnly)
    }

    /// Converts the page's strokes off main, so handing it over in ``setPages(_:)`` doesn't stall a frame.
    public func prepare(_ page: PageSnapshot) async {
        let (strokes, palette, theme, generation) = (
            page.strokes.filter { !Highlight.isHighlight($0) },
            palette,
            theme,
            strokeCache.generation
        )
        guard !strokes.isEmpty else { return }
        let pks = await Task.detached(priority: .userInitiated) {
            strokes.map { PencilKitConversion.pkStroke(from: $0, color: UIColor(palette.ink($0.color, on: theme))) }
        }.value
        strokeCache.insert(strokes, pks, on: page.id, generation: generation)
    }

    // MARK: Canvases

    /// A free canvas, made if the pool allows it.
    func freeCanvas() -> PageCanvas? {
        if let free = canvases.first(where: { $0.page == nil }) {
            return free
        }
        guard canvases.count < maximumCanvases else { return nil }
        let canvas = PageCanvas()
        canvas.view.delegate = self
        canvas.view.onPencilTouch = { [weak self] in self?.pencilSeen() }
        host.insertSubview(canvas.view, belowSubview: selection.view)
        canvases.append(canvas)
        applyTool(to: canvas)
        return canvas
    }

    /// Gives `canvas` to `page`: its drawing is rebuilt and the page's raster stays until it has drawn.
    func assign(_ canvas: PageCanvas, to page: PageID) {
        release(canvas)
        canvas.assign(page)
        rebuildCanvas(canvas)
        capRenderWait(canvas)
    }

    /// Waits for PencilKit to draw the canvas's current placement, at most 0.5 s: `canvasViewDidFinishRendering`
    /// normally comes within a few frames, but the raster must not cover the ink forever if it doesn't.
    func capRenderWait(_ canvas: PageCanvas) {
        let token = canvas.awaitRender()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak canvas] in
            guard let self, let canvas, canvas.renderWait == token, canvas.page != nil else { return }
            canvasDidRender(canvas)
        }
    }

    /// Takes `canvas` off its page (reporting any strokes PencilKit added), empties it and hides it. A
    /// freed canvas holds no ink, so when it is handed to another page it can't show the old page's tiles
    /// there while PencilKit draws the new drawing (the old one-canvas design's "ghost ink" after a pinch).
    /// Never called while a stroke is in progress (``layoutCanvases()``): a stroke commits to the page its
    /// canvas was drawing when it began.
    func release(_ canvas: PageCanvas) {
        guard canvas.page != nil else { return }
        absorbCanvasStrokes(canvas)
        canvas.assign(nil)
        isSettingDrawing = true
        canvas.view.drawing = PKDrawing()
        isSettingDrawing = false
        canvas.ids = []
    }

    /// PencilKit drew the canvas's page: the raster underneath can leave the drawn region to it. Fires
    /// after every render (a page it just got, more page after a scroll or a settled zoom).
    private func canvasDidRender(_ canvas: PageCanvas) {
        guard let region = canvas.placement?.region, canvas.renderedRegion != region else { return }
        canvas.renderedRegion = region
        layoutPages()
        if let page = canvas.page, snapshots[page]?.isLoaded == true {
            delegate?.engine(self, didShowSharpInkOn: page)
        }
    }

    private func contentChanged(_ page: PageID, rebuild: Bool) {
        if let canvas = canvas(for: page) {
            let shown = (snapshots[page]?.strokes ?? []).filter { !Highlight.isHighlight($0) && !selection.strokes.contains($0.id) }
            let desired = shown.map(\.id) + (pending[page] ?? []).filter { !$0.isHighlight }.map(\.id)
            if rebuild || desired != canvas.ids {
                rebuildCanvas(canvas)
            }
        }
        layoutPages()
    }

    /// Replaces `canvas`'s drawing with its page's ink (never highlights) plus pending strokes.
    func rebuildCanvas(_ canvas: PageCanvas) {
        guard !canvas.isUsingTool else {
            canvas.needsRebuild = true
            return
        }
        canvas.needsRebuild = false
        rebuildCount += 1
        if canvas.view.drawing.strokes.count > canvas.ids.count {
            absorbCanvasStrokes(canvas)
        }
        var strokes: [PKStroke] = []
        var ids: [StrokeID] = []
        if let page = canvas.page, let snapshot = snapshots[page] {
            let shown = snapshot.strokes.filter { !Highlight.isHighlight($0) && !selection.strokes.contains($0.id) }
            strokes = strokeCache.pkStrokes(shown, on: page) { PencilKitConversion.pkStroke(from: $0, color: uiColor($0.color)) }
            ids = shown.map(\.id)
            for case let (id, pk)? in (pending[page] ?? []).map(\.ink) {
                strokes.append(pk)
                ids.append(id)
            }
        }
        isSettingDrawing = true
        canvas.view.drawing = PKDrawing(strokes: strokes)
        isSettingDrawing = false
        canvas.ids = ids
    }
}

extension PencilKitInkEngine {
    /// The canvas drawing `page`, if it has one.
    func canvas(for page: PageID) -> PageCanvas? {
        canvases.first { $0.page == page }
    }

    /// The pooled canvas behind `view`.
    func canvas(of view: PKCanvasView) -> PageCanvas? {
        canvases.first { $0.view === view }
    }

    /// Rebuilds the canvas of `page`, if it has one.
    func rebuildCanvas(for page: PageID) {
        if let canvas = canvas(for: page) {
            rebuildCanvas(canvas)
        }
    }
}

// MARK: - PKCanvasViewDelegate

extension PencilKitInkEngine: PKCanvasViewDelegate {
    public func canvasViewDidBeginUsingTool(_ view: PKCanvasView) {
        canvas(of: view)?.isUsingTool = true
        canvas(of: view)?.discardsStroke = false
        delegate?.engineDidBeginStroke(self)
    }

    public func canvasViewDidEndUsingTool(_ view: PKCanvasView) {
        guard let canvas = canvas(of: view) else { return }
        canvas.isUsingTool = false
        absorbCanvasStrokes(canvas)
        if canvas.needsRebuild {
            rebuildCanvas(canvas)
        }
    }

    public func canvasViewDrawingDidChange(_ view: PKCanvasView) {
        guard !isSettingDrawing, let canvas = canvas(of: view) else { return }
        absorbCanvasStrokes(canvas)
    }

    public func canvasViewDidFinishRendering(_ view: PKCanvasView) {
        guard let canvas = canvas(of: view) else { return }
        canvasDidRender(canvas)
        canvasDidRenderSelection()
        flatPenCanvasDidRender(canvas)
        crossPageCanvasDidRender(canvas)
    }
}
