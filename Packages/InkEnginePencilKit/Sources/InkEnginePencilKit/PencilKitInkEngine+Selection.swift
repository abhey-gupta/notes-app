import InkEngine
import InkModel
import PencilKit
import UIKit

/// Lasso chrome the engine draws (ARCHITECTURE.md §6): the live lasso path, and the lifted-strokes preview
/// for lasso drags and resizes. Both live in the engine view (content space), so they zoom with the page
/// (the lasso's dash is scaled back so it stays 1.5 pt on screen).
///
/// Lifting shows the selected strokes as one image (`selection.lifted`, rendered off main as soon as the
/// selection is made, ``prepareSelectionPreview(_:on:)``) and leaves them out of the page's canvas; every
/// drag frame then only sets the layer's transform, so the cost per frame doesn't depend on how many
/// strokes are selected (120 Hz with hundreds). When the preview ends the strokes go back on the canvas
/// (by then at their baked position) and the image stays until the canvas has drawn them.
extension PencilKitInkEngine {
    /// Color of the live lasso path.
    public var selectionColor: UIColor {
        get { selection.color }
        set { selection.color = newValue }
    }

    func setUpSelectionLayers() {
        selection.view.isUserInteractionEnabled = false
        selection.view.frame = host.bounds
        selection.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(selection.view)
        selection.lifted.anchorPoint = .zero
        selection.lifted.position = .zero
        selection.lifted.isHidden = true
        selection.view.layer.addSublayer(selection.lifted)
        selection.lasso.fillColor = nil
        selection.lasso.strokeColor = selection.color.cgColor
        selection.lasso.lineWidth = 1.5
        selection.lasso.lineCap = .round
        selection.lasso.lineJoin = .round
        selection.lasso.lineDashPattern = [5, 4]
        selection.view.layer.addSublayer(selection.lasso)
        setUpFlatPen()
        setUpEraserCursor()
        setUpLaser()
    }

    public func setSelectionPreview(_ preview: SelectionPreview?) {
        // Photos move as their own layers (`+Photos`); the lifted image is ink only.
        setPhotoPreview(preview
            .flatMap { $0.images.isEmpty ? nil : PhotoPreview(page: $0.page, images: $0.images, transform: $0.transform) })
        guard let preview, !preview.strokes.isEmpty, snapshots[preview.page] != nil else {
            endSelectionPreview()
            return
        }
        if selection.strokes != preview.strokes || selection.preview?.page != preview.page {
            lift(preview)
        }
        selection.preview = preview
        layoutSelectionPreview()
    }

    public func prepareSelectionPreview(_ strokes: Set<StrokeID>, on page: PageID) {
        selection.prepareTask?.cancel()
        selection.prepareTask = nil
        selection.prepared = nil
        guard !strokes.isEmpty, let snapshot = snapshots[page] else { return }
        let lift = liftRender(strokes, of: snapshot)
        selection.prepareTask = Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) { lift.render() }.value
            guard let self, !Task.isCancelled else { return }
            selection.prepared = (lift.key, image)
            selection.prepareTask = nil
        }
    }

    /// What lifting `strokes` of `snapshot` renders, at the current zoom.
    private func liftRender(_ ids: Set<StrokeID>, of snapshot: PageSnapshot) -> LiftRender {
        let strokes = snapshot.strokes.filter { ids.contains($0.id) }
        let rect = strokes.reduce(CGRect.null) { $0.union($1.bounds) }.intersection(CGRect(origin: .zero, size: snapshot.size))
        let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
        let longest = max(rect.width, rect.height, 1)
        let scale = min(max(screenScale, 1) * max(viewport.zoomScale, 0.25), maximumRasterDimension / longest)
        let lifted = PageSnapshot(page: Page(id: snapshot.id, strokes: strokes), size: snapshot.size)
        return LiftRender(
            key: LiftRender.Key(page: snapshot.id, strokes: ids, rev: snapshot.rev, theme: theme),
            job: RenderJob(page: lifted, palette: palette, theme: theme), rect: rect, scale: scale
        )
    }

    /// Shows the strokes' image in `selection.lifted` (the prepared one if current, else rendered now)
    /// and takes them off the page's canvas.
    private func lift(_ preview: SelectionPreview) {
        guard let snapshot = snapshots[preview.page] else { return }
        let previousPage = selection.preview?.page
        selection.generation += 1
        let lift = liftRender(preview.strokes, of: snapshot)
        let rect = lift.rect
        selection.rect = rect
        if let prepared = selection.prepared, prepared.key == lift.key {
            selection.lifted.contents = prepared.image
        } else {
            selection.syncRenderCount += 1
            selection.lifted.contents = lift.render()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.lifted.bounds = CGRect(origin: .zero, size: rect.isNull ? .zero : rect.size)
        CATransaction.commit()
        selection.strokes = preview.strokes
        rebuildCanvas(for: preview.page)
        if let previousPage, previousPage != preview.page {
            rebuildCanvas(for: previousPage)
        }
        layoutPages()
    }

    /// Puts the strokes back on the canvas; the image goes once the canvas has drawn them. Lifted
    /// highlights stay out of their page view until then too, so the image never doubles them; a
    /// selection of highlights alone waits for nothing.
    private func endSelectionPreview() {
        guard selection.preview != nil || !selection.strokes.isEmpty else { return }
        let page = selection.preview?.page
        let lifted = page.flatMap { snapshots[$0]?.strokes.filter { selection.strokes.contains($0.id) } } ?? []
        selection.strokes = []
        selection.liftedHighlights = Set(lifted.filter(Highlight.isHighlight).map(\.id))
        if let page {
            rebuildCanvas(for: page)
        }
        layoutPages()
        selection.generation += 1
        guard lifted.contains(where: { !Highlight.isHighlight($0) }) else {
            removeLiftedImage()
            return
        }
        let generation = selection.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, selection.generation == generation else { return }
            removeLiftedImage()
        }
    }

    /// `canvasViewDidFinishRendering`: an ended preview's image can go.
    func canvasDidRenderSelection() {
        if selection.strokes.isEmpty, selection.preview != nil {
            removeLiftedImage()
        }
    }

    private func removeLiftedImage() {
        selection.preview = nil
        selection.rect = .null
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.lifted.isHidden = true
        selection.lifted.contents = nil
        CATransaction.commit()
        if !selection.liftedHighlights.isEmpty {
            selection.liftedHighlights = []
            layoutPages()
        }
    }

    /// Places the lifted image: page-space preview transform, then page → content.
    func layoutSelectionPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let preview = selection.preview, !selection.rect.isNull, let page = viewport.page(preview.page) else {
            selection.lifted.isHidden = true
            return
        }
        selection.lifted.isHidden = false
        selection.lifted.setAffineTransform(
            CGAffineTransform(translationX: selection.rect.minX, y: selection.rect.minY)
                .concatenating(preview.transform)
                .concatenating(CGAffineTransform(translationX: page.frame.minX, y: page.frame.minY))
        )
    }

    /// Dashed live lasso path while the lasso is down.
    func drawLasso(_ event: InkInputTracker.Event) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case let .began(stroke), let .updated(stroke):
            let pageToContent = stroke.viewToPage.inverted()
            let path = CGMutablePath()
            path.addLines(between: stroke.displaySamples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)).applying(pageToContent) })
            // The layer zooms with the page; keep the dash 1.5 pt on screen.
            let onScreen = 1 / max(viewport.zoomScale, 0.01)
            selection.lasso.lineWidth = 1.5 * onScreen
            selection.lasso.lineDashPattern = [5 * onScreen, 4 * onScreen] as [NSNumber]
            selection.lasso.path = path
        case .ended, .cancelled:
            selection.lasso.path = nil
        }
    }
}

/// What the selection chrome draws and which strokes are lifted.
@MainActor
final class SelectionLayers {
    let view = UIView()
    /// Image of the lifted strokes.
    let lifted = CALayer()
    /// Live lasso path.
    let lasso = CAShapeLayer()
    /// Eraser reach under the tip (`+EraserCursor`).
    let eraser = CAShapeLayer()
    /// PencilKit's image of the live stroke of a pen with pressure off (`+FlatPen`, #123).
    let flatPen = CALayer()
    /// The stroke `flatPen` draws the live samples as (ID, seed, rendering).
    var flatPenStroke: Stroke?
    /// The live stroke, while the pen is down.
    var flatPenLive: LiveStroke?
    /// Committed strokes `flatPen` keeps showing until `flatPenCanvas` has drawn them.
    var flatPenSettling: [Stroke] = []
    /// Page of the settling strokes.
    var flatPenSettlingPage: PageID?
    /// Canvas whose next render lets the settling strokes go (it has them).
    weak var flatPenCanvas: PageCanvas?
    /// The preview `lifted` shows (kept after it ends until the canvas has redrawn the strokes).
    var preview: SelectionPreview?
    /// Strokes left out of the canvas while the preview draws them.
    var strokes: Set<StrokeID> = []
    /// Highlights of an ended preview, left out of their page view until the lifted image goes.
    var liftedHighlights: Set<StrokeID> = []
    /// The highlight being drawn (`+Highlighter`, #120).
    var liveHighlight: LiveHighlight?
    /// Photos drawn moved in place during a drag (#157).
    var photoPreview: PhotoPreview?
    /// Page-space rect the `lifted` image covers.
    var rect = CGRect.null
    var generation = 0
    /// Image rendered off main when the selection was made, and the render in flight.
    var prepared: (key: LiftRender.Key, image: CGImage?)?
    var prepareTask: Task<Void, Never>?
    /// Lifts that had to render on main (no current prepared image).
    var syncRenderCount = 0
    var color = UIColor.systemBlue {
        didSet { lasso.strokeColor = color.cgColor }
    }
}

/// Rendering the lifted strokes: inputs (all `Sendable`) and the key that says whether an image still fits.
struct LiftRender: Sendable {
    struct Key: Hashable, Sendable {
        let page: PageID
        let strokes: Set<StrokeID>
        let rev: UInt64
        let theme: PaperTheme
    }

    let key: Key
    let job: RenderJob
    /// Page-space rect the image covers.
    let rect: CGRect
    let scale: CGFloat

    func render() -> CGImage? {
        rect.isNull || rect.isEmpty ? nil : job.ink(in: rect, scale: scale)
    }
}
