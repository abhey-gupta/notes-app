import CoreGraphics
import InkEngine
import InkGeometry
import InkModel
import Metal
import os
import Perf
import UIKit

/// Shelved `InkEngine` (spike #16, ARCHITECTURE.md §3): custom Metal ink at the hardware latency floor.
/// Predates the content-sized engine view: it still draws as if its view were pinned to the visible rect
/// (`Viewport.viewRect`), so wiring it into the host again means moving it to content space first.
///
/// **Frame** (one command buffer, presented on a two-drawable `CAMetalLayer`):
/// 1. ``CommittedContentRenderer/prepare(_:commandBuffer:)``: re-renders committed content only if
///    the viewport, pages, theme or committed ink changed (today one viewport-sized composite; tiles
///    in #22).
/// 2. If a highlighter is live or pending: its coverage pass (max blend, no self-overlap darkening).
/// 3. Drawable pass: committed content (one fullscreen triangle), pending strokes (committed, not yet
///    echoed by the document), highlighter resolve (multiply on light paper, screen on Night), live
///    stroke with its predicted tail, lasso/eraser overlay.
///
/// **When**: live-stroke frames are drawn synchronously inside the touch event that delivered the
/// samples (``InkEngine/InkInputView``); everything else (viewport, edits, theme) on the next vsync
/// of a `CADisplayLink` that runs at 120 Hz only while ink or scrolling is active.
///
/// **Committed geometry**: per-page GPU buffers (``PageBuffers``) built off main from `InkGeometry`
/// tessellation, with tessellated strips cached by stroke ID (and validated against the stroke's
/// width, tool, sample count and bounds). ``apply(_:to:)`` and ``invalidate(_:in:)`` rebuild a page;
/// only new or changed strokes are re-tessellated.
///
/// Colors resolve at render time from `InkColor` through the injected ``InkEngine/InkPalette`` for
/// the current `PaperTheme`.
@MainActor
public final class MetalInkEngine: InkEngine {
    public var view: UIView {
        hostView
    }

    public weak var delegate: (any InkEngineDelegate)?
    /// Unused: the live lasso path is drawn in the palette's primary ink.
    public var selectionColor: UIColor = .systemBlue
    /// Unused: pages draw from geometry at once, with no thumbnail phase.
    public var thumbnailURL: ((PageID) -> URL?)?

    /// Pen-to-pixel latency (touch timestamp → presented time), also shown in the debug HUD.
    public let latency = LatencyProbe()

    let gpu: GPUContext
    private(set) var palette: any InkPalette
    let hostView: MetalInkView
    let content: any CommittedContentRenderer
    let ring: FrameBufferRing
    lazy var driver = FrameDriver { [weak self] in self?.drawFrame() }

    private(set) var viewport = Viewport.empty
    private(set) var snapshots: [PageID: PageSnapshot] = [:]
    private(set) var tool = ToolConfiguration.default
    private(set) var theme = PaperTheme.white

    /// Committed geometry.
    /// Tessellated strips by stroke ID (pages in ``snapshots`` plus pending strokes).
    private(set) var meshCache: [StrokeID: StrokeGeometry] = [:]
    /// Latest finished build per page (may lag the snapshot by one build).
    private(set) var pageBuffers: [PageID: PageBuffers] = [:]
    /// In-flight build per page (at most one; later requests coalesce into one rebuild after it).
    private var buildTasks: [PageID: (token: Int, task: Task<Void, Never>)] = [:]
    private var nextBuildToken = 0
    private var rebuildAfterCurrent: Set<PageID> = []
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

    private(set) var pending: [PageID: [PendingStroke]] = [:]
    private var eraserEmitted = 0
    private var lastProbedTimestamp: TimeInterval = 0
    var frameCoverage: (any MTLTexture)?
    /// Frames presented so far (tests).
    var frameCount = 0

    private static let log = Logger(subsystem: "com.abhey.notespace", category: "ink.metal")

    /// Creates the engine, or `nil` if Metal is unavailable (use the PencilKit adapter then).
    /// - Parameter palette: Resolves paper and ink colors (the app adapts `DesignSystem`).
    public init?(palette: any InkPalette) {
        guard let gpu = GPUContext.shared else { return nil }
        self.gpu = gpu
        self.palette = palette
        hostView = MetalInkView(device: gpu.device)
        content = ViewportCompositeRenderer(gpu: gpu)
        ring = FrameBufferRing(device: gpu.device)
        hostView.input.delegate = self
        hostView.onResize = { [weak self] in
            self?.content.setNeedsUpdate(page: nil, rect: nil)
            self?.frameCoverage = nil
            self?.driver.requestFrame()
        }
        latency.registerGauge()
    }

    // MARK: InkEngine

    public func setViewport(_ viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        content.setNeedsUpdate(page: nil, rect: nil)
        driver.viewportDidChange()
    }

    public func setPages(_ pages: [PageSnapshot]) {
        let old = snapshots
        snapshots = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in old.keys where snapshots[id] == nil {
            pageBuffers[id] = nil
            pending[id] = nil
            buildTasks[id]?.task.cancel()
            buildTasks[id] = nil
            rebuildAfterCurrent.remove(id)
        }
        for (id, snapshot) in snapshots where old[id] != snapshot || pageBuffers[id] == nil {
            scheduleBuild(id)
        }
        pruneMeshCache()
        content.setNeedsUpdate(page: nil, rect: nil)
        driver.requestFrame()
    }

    public func setTool(_ tool: ToolConfiguration) {
        if tool.tool != self.tool.tool {
            hostView.input.cancelActiveStroke()
        }
        self.tool = tool
        hostView.input.allowsFingerDrawing = tool.allowsFingerDrawing
        hostView.input.recordsForce = tool.pressure
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

    public func setPalette(_ palette: any InkPalette) {
        self.palette = palette
        for id in snapshots.keys {
            scheduleBuild(id)
        }
        driver.requestFrame()
    }

    /// No lifted-strokes preview: selected strokes stay in place until the baked edit arrives.
    public func setSelectionPreview(_: SelectionPreview?) {}

    public func prepareSelectionPreview(_: Set<StrokeID>, on _: PageID) {}

    /// Page buffers build off main already (on `setPages`).
    public func prepare(_: PageSnapshot) async {}

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

    /// Redraws `rect` (page space) of `page`.
    public func invalidate(_ rect: CGRect, in page: PageID) {
        guard let snapshot = snapshots[page] else { return }
        for stroke in snapshot.strokes where stroke.bounds.intersects(rect) {
            meshCache[stroke.id] = nil
        }
        scheduleBuild(page)
        content.setNeedsUpdate(page: page, rect: rect)
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

    private func scheduleBuild(_ page: PageID) {
        guard buildTasks[page] == nil else {
            rebuildAfterCurrent.insert(page)
            return
        }
        guard let snapshot = snapshots[page] else { return }
        let input = PageBuildInput(
            snapshot: snapshot,
            theme: theme,
            palette: palette,
            fringe: PageBuilder.fringe,
            cached: cachedGeometry(for: snapshot.strokes)
        )
        let device = gpu.device
        nextBuildToken += 1
        let token = nextBuildToken
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
        pageBuffers[page] = buffers
        buildCount += 1
        tessellationCount += build.tessellated
        meshCache.merge(build.geometry) { _, new in new }
        pending[page]?.removeAll { buffers.strokeIDs.contains($0.stroke.id) }
        if rebuildAfterCurrent.remove(page) != nil {
            scheduleBuild(page)
        }
        content.setNeedsUpdate(page: page, rect: nil)
        driver.requestFrame()
        delegate?.engine(self, didShowSharpInkOn: page)
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
