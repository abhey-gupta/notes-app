import CoreGraphics
import InkEngine
import InkGeometry
import InkModel
import Metal
import os
import Perf
import UIKit

/// The shipping `InkEngine`: custom Metal ink at the hardware latency floor (ARCHITECTURE.md §3).
///
/// **Frame** (one command buffer, presented on a two-drawable `CAMetalLayer`):
/// 1. ``CommittedContentRenderer/prepare(_:commandBuffer:)``: committed content. With tiles (default,
///    ``TiledContentRenderer``) it only collects tiles rendered off main and plans which to draw; with
///    ``CommittedContentMode/viewportComposite`` it re-renders one viewport-sized texture on any change.
/// 2. If a highlighter is live or pending: its coverage pass (max blend, no self-overlap darkening).
/// 3. Drawable pass: committed content (tile quads or one fullscreen triangle), pending strokes
///    (committed, until the content shown includes them), highlighter resolve (multiply on light
///    paper, screen on Night), live stroke with its predicted tail, lasso/eraser overlay.
///
/// **When**: live-stroke frames are drawn synchronously inside the touch event that delivered the
/// samples (``InkEngine/InkInputView``); everything else (viewport, edits, theme) on the next vsync
/// of a `CADisplayLink` that runs at 120 Hz only while ink or scrolling is active.
///
/// **Committed geometry**: per-page GPU buffers (``PageBuffers``) built off main from `InkGeometry`
/// tessellation, with tessellated strips cached by stroke ID (and validated against the stroke's
/// width, tool, sample count and bounds). ``apply(_:to:)`` and ``invalidate(_:in:)`` rebuild a page;
/// only new or changed strokes are re-tessellated, and only tiles over strokes that changed between
/// builds re-render (``PageDiff``). Buffers and strips of pages more than ``bufferRadius`` pages
/// (in ``setPages(_:)`` order) from the visible ones are dropped and rebuilt on return.
///
/// Colors resolve at render time from `InkColor` through the injected ``InkEngine/InkPalette`` for
/// the current `PaperTheme`.
@MainActor
public final class MetalInkEngine: InkEngine {
    public var view: UIView {
        hostView
    }

    public weak var delegate: (any InkEngineDelegate)?

    /// Pen-to-pixel latency (touch timestamp → presented time), also shown in the debug HUD.
    public let latency = LatencyProbe()

    let gpu: GPUContext
    let palette: any InkPalette
    let hostView: MetalInkView
    let content: any CommittedContentRenderer
    /// The tile renderer, unless running the viewport composite.
    let tiles: TiledContentRenderer?
    let ring: FrameBufferRing
    lazy var driver = FrameDriver { [weak self] in self?.drawFrame() }

    private(set) var viewport = Viewport.empty
    private(set) var snapshots: [PageID: PageSnapshot] = [:]
    private(set) var tool = ToolConfiguration.default
    private(set) var theme = PaperTheme.white

    /// Committed geometry.
    /// Tessellated strips by stroke ID (pages in ``snapshots`` plus pending strokes).
    var meshCache: [StrokeID: StrokeGeometry] = [:]
    /// Latest finished build per page (may lag the snapshot by one build).
    var pageBuffers: [PageID: PageBuffers] = [:]
    /// In-flight build per page (at most one; later requests coalesce into one rebuild after it).
    var buildTasks: [PageID: (token: Int, task: Task<Void, Never>)] = [:]
    private var nextBuildToken = 0
    var rebuildAfterCurrent: Set<PageID> = []
    /// Look of each page's last installed build (kept when its buffers are dropped).
    var signatures: [PageID: PageSignature] = [:]
    /// Rects passed to ``invalidate(_:in:)``, applied when the rebuild they caused installs.
    var explicitInvalidations: [PageID: CGRect] = [:]
    /// Position of each page in the last ``setPages(_:)`` (document order).
    var pageOrder: [PageID: Int] = [:]
    /// Order indices whose buffers are kept (visible ± ``bufferRadius``); `nil`: all.
    var bufferWindow: ClosedRange<Int>?
    /// Strokes tessellated by page builds so far (cache misses; tests).
    private(set) var tessellationCount = 0
    /// Page builds finished so far (tests).
    private(set) var buildCount = 0

    /// Live input.
    struct Live {
        var stroke: LiveStroke
        var tool: ToolConfiguration
    }

    /// The gesture under the Pencil and the tool it started with.
    private(set) var live: Live?
    /// A stroke reported via `didCommit` and drawn on top until a page build includes it.
    struct PendingStroke {
        let stroke: Stroke
        let buffer: (any MTLBuffer)?
        let vertexCount: Int
        let ends: StrokeEnds
    }

    var pending: [PageID: [PendingStroke]] = [:]
    private var eraserEmitted = 0
    private var lastProbedTimestamp: TimeInterval = 0
    var frameCoverage: (any MTLTexture)?
    /// Frames presented so far (tests).
    var frameCount = 0

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "ink.metal")

    /// Creates the engine, or `nil` if Metal is unavailable (use the PencilKit adapter then).
    /// - Parameters:
    ///   - palette: Resolves paper and ink colors (the app adapts `DesignSystem`).
    ///   - contentMode: Tiles, or the viewport composite for A/B (``CommittedContentMode/default``).
    public init?(palette: any InkPalette, contentMode: CommittedContentMode = .default) {
        guard let gpu = GPUContext.shared else { return nil }
        self.gpu = gpu
        self.palette = palette
        hostView = MetalInkView(device: gpu.device)
        let tiles = contentMode == .tiles ? TiledContentRenderer(gpu: gpu) : nil
        self.tiles = tiles
        content = tiles ?? ViewportCompositeRenderer(gpu: gpu)
        ring = FrameBufferRing(device: gpu.device)
        hostView.input.delegate = self
        hostView.onResize = { [weak self] in
            self?.content.setNeedsDisplay()
            self?.frameCoverage = nil
            self?.driver.requestFrame()
        }
        tiles?.onNeedsFrame = { [weak self] in self?.driver.requestFrame() }
        latency.registerGauge()
    }

    // MARK: InkEngine

    public func setViewport(_ viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        content.setNeedsDisplay()
        updateBufferWindow()
        driver.viewportDidChange()
    }

    public func setPages(_ pages: [PageSnapshot]) {
        let old = snapshots
        snapshots = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        pageOrder = Dictionary(pages.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in old.keys where snapshots[id] == nil {
            pageBuffers[id] = nil
            pending[id] = nil
            buildTasks[id]?.task.cancel()
            buildTasks[id] = nil
            rebuildAfterCurrent.remove(id)
            explicitInvalidations[id] = nil
        }
        bufferWindow = nil
        updateBufferWindow()
        for (id, snapshot) in snapshots where old[id] != snapshot || pageBuffers[id] == nil {
            scheduleBuild(id)
        }
        pruneMeshCache()
        content.setNeedsDisplay()
        driver.requestFrame()
    }

    public func setTool(_ tool: ToolConfiguration) {
        if tool.tool != self.tool.tool {
            hostView.input.cancelActiveStroke()
        }
        self.tool = tool
        hostView.input.allowsFingerDrawing = tool.allowsFingerDrawing
    }

    public func setTheme(_ theme: PaperTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        // Pages keep showing their previous build (paper and ink of one theme) until the rebuild with
        // the new styles lands; nothing is re-tessellated.
        for id in snapshots.keys {
            scheduleBuild(id)
        }
        driver.requestFrame()
    }

    public func apply(_ edit: PageEdit, to page: PageID) {
        guard let snapshot = snapshots[page] else { return }
        do {
            snapshots[page] = try snapshot.applying(edit)
        } catch {
            Self.log.error("apply failed on \(page, privacy: .public): \(String(describing: error), privacy: .public)")
            return
        }
        if case let .transform(ids, _, _) = edit {
            for id in ids {
                meshCache[id] = nil
            }
        }
        scheduleBuild(page)
    }

    public func invalidate(_ rect: CGRect, in page: PageID) {
        guard let snapshot = snapshots[page] else { return }
        for stroke in snapshot.strokes where stroke.bounds.intersects(rect) {
            meshCache[stroke.id] = nil
        }
        guard isInBufferWindow(page) else {
            // Not built while off-window: drop the tiles now; they re-render when the page returns.
            content.invalidate(page: page, rect: rect)
            return
        }
        // Tiles re-render once the rebuild lands (``install(_:page:token:)``), not with the old buffers.
        explicitInvalidations[page] = explicitInvalidations[page].map { $0.union(rect) } ?? rect
        scheduleBuild(page)
    }

    public func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage? {
        guard size.width > 0, size.height > 0, scale > 0, size.width.isFinite, size.height.isFinite, scale.isFinite else { return nil }
        let job = OffscreenRenderer.Job(
            gpu: gpu,
            page: page,
            size: size,
            scale: scale,
            theme: theme,
            palette: palette,
            cached: cachedGeometry(for: page.strokes)
        )
        return await OffscreenRenderer.render(job)
    }

    // MARK: Page builds

    func scheduleBuild(_ page: PageID) {
        guard isInBufferWindow(page) else { return }
        guard buildTasks[page] == nil else {
            rebuildAfterCurrent.insert(page)
            return
        }
        guard let snapshot = snapshots[page] else { return }
        nextBuildToken += 1
        let token = nextBuildToken
        var input = PageBuildInput(
            snapshot: snapshot,
            theme: theme,
            palette: palette,
            fringe: PageBuilder.fringe,
            cached: cachedGeometry(for: snapshot.strokes)
        )
        input.version = token
        let device = gpu.device
        let task = Task { [weak self] in
            let build = await PageBuilder.build(input, device: device)
            self?.install(build, page: page, token: token)
        }
        buildTasks[page] = (token, task)
    }

    private func install(_ build: PageBuild, page: PageID, token: Int) {
        // A page dropped by `setPages` (and maybe re-added since) ignores builds it no longer owns.
        guard buildTasks[page]?.token == token, snapshots[page] != nil else { return }
        buildTasks[page] = nil
        let buffers = build.buffers
        invalidateContent(page, installing: buffers, last: !rebuildAfterCurrent.contains(page))
        pageBuffers[page] = buffers
        signatures[page] = PageSignature(buffers)
        buildCount += 1
        tessellationCount += build.tessellated
        meshCache.merge(build.geometry) { _, new in new }
        // Pending strokes stay on top until the content shown includes them (``prunePending()``).
        if rebuildAfterCurrent.remove(page) != nil {
            scheduleBuild(page)
        }
        content.setNeedsDisplay()
        driver.requestFrame()
    }

    private func cachedGeometry(for strokes: [Stroke]) -> [StrokeID: StrokeGeometry] {
        var cached: [StrokeID: StrokeGeometry] = [:]
        cached.reserveCapacity(strokes.count)
        for stroke in strokes {
            if let g = meshCache[stroke.id] {
                cached[stroke.id] = g
            }
        }
        return cached
    }

    /// Drops cached strips for strokes no longer on any retained page (kept across edits so undo of
    /// an erase re-uses them).
    private func pruneMeshCache() {
        var keep = Set<StrokeID>()
        for snapshot in snapshots.values {
            for stroke in snapshot.strokes {
                keep.insert(stroke.id)
            }
        }
        for list in pending.values {
            for entry in list {
                keep.insert(entry.stroke.id)
            }
        }
        meshCache = meshCache.filter { keep.contains($0.key) }
    }

    /// Waits until no page build is in flight (tests, previews).
    func waitForBuilds() async {
        while let entry = buildTasks.values.first {
            await entry.task.value
        }
    }

    // MARK: Commit

    func commit(_ stroke: LiveStroke, tool config: ToolConfiguration) {
        guard let kind = config.penKind, !stroke.samples.isEmpty else { return }
        let interval = Signpost.strokeCommit.begin()
        defer { interval.end() }
        let committed = Stroke(tool: kind, color: config.color, width: config.width, samples: stroke.samples)
        let geometry = StrokeGeometry(committed, fringe: PageBuilder.fringe)
        meshCache[committed.id] = geometry
        let buffer = geometry.vertices.withUnsafeBytes { raw in
            raw.baseAddress.flatMap { gpu.device.makeBuffer(bytes: $0, length: raw.count, options: .storageModeShared) }
        }
        pending[stroke.page, default: []].append(PendingStroke(
            stroke: committed,
            buffer: buffer,
            vertexCount: geometry.vertices.count,
            ends: geometry.ends
        ))
        delegate?.engine(self, didCommit: committed, to: stroke.page)
    }
}

// MARK: - Input

extension MetalInkEngine: InkInputViewDelegate {
    public func inkInputView(_: InkInputView, targetAt point: CGPoint) -> InkInputTarget? {
        guard let page = viewport.page(at: point) else { return nil }
        return InkInputTarget(page: page.id, viewToPage: viewport.viewToPage(page))
    }

    public func inkInputView(_: InkInputView, didProduce event: InkInputTracker.Event) {
        switch event {
        case let .began(stroke):
            live = Live(stroke: stroke, tool: tool)
            eraserEmitted = 0
            driver.setInkActive(true)
            delegate?.engineDidBeginStroke(self)
            progress(stroke, ended: false)
        case let .updated(stroke):
            progress(stroke, ended: false)
        case let .ended(stroke):
            progress(stroke, ended: true)
        case let .cancelled(stroke):
            guard live?.stroke.touch == stroke.touch else { return }
            live = nil
            driver.setInkActive(false)
            drawFrame()
        }
    }

    /// New samples for the live gesture: draw now (pens), or forward (eraser, lasso) and draw the overlay.
    func progress(_ stroke: LiveStroke, ended: Bool) {
        guard var current = live, current.stroke.touch == stroke.touch else { return }
        current.stroke = stroke
        live = current
        switch current.tool.tool {
        case .pen:
            if ended {
                commit(stroke, tool: current.tool)
            }
        case .eraser:
            if stroke.samples.count > eraserEmitted {
                let fresh = Array(stroke.samples[eraserEmitted...])
                eraserEmitted = stroke.samples.count
                delegate?.engine(self, didReceiveEraser: fresh, to: stroke.page)
            }
        case .lasso:
            if ended {
                delegate?.engine(self, didReceiveLasso: stroke.samples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }, to: stroke.page)
            }
        }
        if ended {
            live = nil
            driver.setInkActive(false)
        }
        // Only frames that show new touches count for latency (estimate patches don't).
        var timestamp: TimeInterval?
        if !ended, stroke.latestTimestamp > lastProbedTimestamp {
            timestamp = stroke.latestTimestamp
            lastProbedTimestamp = stroke.latestTimestamp
        }
        drawFrame(touchTimestamp: timestamp)
    }
}
