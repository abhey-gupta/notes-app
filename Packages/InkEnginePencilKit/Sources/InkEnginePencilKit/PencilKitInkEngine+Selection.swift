import InkEngine
import InkModel
import PencilKit
import UIKit

/// Lasso chrome the engine draws (ARCHITECTURE.md §6): the live lasso path, and the lifted-strokes preview
/// for lasso drags and resizes.
///
/// Lifting renders the selected strokes once into an image (`selection.lifted`) and leaves them out of the
/// canvas; every drag frame then only sets the layer's transform, so the cost per frame doesn't depend on
/// how many strokes are selected (120 Hz with hundreds). When the preview ends the strokes go back on the
/// canvas (by then at their baked position) and the image stays until the canvas has drawn them.
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
    }

    public func setSelectionPreview(_ preview: SelectionPreview?) {
        guard let preview, !preview.strokes.isEmpty, snapshots[preview.page] != nil else {
            endSelectionPreview()
            return
        }
        if preview.page != activePage {
            activate(preview.page)
        }
        if selection.strokes != preview.strokes || selection.preview?.page != preview.page {
            lift(preview)
        }
        selection.preview = preview
        layoutSelectionPreview()
    }

    /// Renders the strokes into `selection.lifted` and takes them off the canvas.
    private func lift(_ preview: SelectionPreview) {
        guard let snapshot = snapshots[preview.page] else { return }
        selection.generation += 1
        let strokes = snapshot.strokes.filter { preview.strokes.contains($0.id) }
        let rect = strokes.reduce(CGRect.null) { $0.union($1.bounds) }.intersection(CGRect(origin: .zero, size: snapshot.size))
        selection.rect = rect
        selection.lifted.contents = nil
        if !rect.isNull, !rect.isEmpty {
            let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
            let longest = max(rect.width, rect.height, 1)
            let scale = min(max(screenScale, 1) * max(viewport.zoomScale, 0.25), maximumRasterDimension / longest)
            let lifted = PageSnapshot(page: Page(id: snapshot.id, strokes: strokes), size: snapshot.size)
            let drawing = RenderJob(page: lifted, palette: palette, theme: theme).drawing()
            var image: CGImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = drawing.image(from: rect, scale: scale).cgImage
            }
            selection.lifted.contents = image
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selection.lifted.bounds = CGRect(origin: .zero, size: rect.isNull ? .zero : rect.size)
        CATransaction.commit()
        selection.strokes = preview.strokes
        rebuildCanvas()
    }

    /// Puts the strokes back on the canvas; the image goes once the canvas has drawn them.
    private func endSelectionPreview() {
        guard selection.preview != nil || !selection.strokes.isEmpty else { return }
        selection.strokes = []
        rebuildCanvas()
        selection.generation += 1
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
    }

    /// Places the lifted image: page-space preview transform, then page → view.
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
                .concatenating(viewport.pageToView(page))
        )
    }

    /// Dashed live lasso path while the lasso is down.
    func drawLasso(_ event: InkInputTracker.Event) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch event {
        case let .began(stroke), let .updated(stroke):
            let pageToView = stroke.viewToPage.inverted()
            let path = CGMutablePath()
            path.addLines(between: stroke.displaySamples.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)).applying(pageToView) })
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
    /// The preview `lifted` shows (kept after it ends until the canvas has redrawn the strokes).
    var preview: SelectionPreview?
    /// Strokes left out of the canvas while the preview draws them.
    var strokes: Set<StrokeID> = []
    /// Page-space rect the `lifted` image covers.
    var rect = CGRect.null
    var generation = 0
    var color = UIColor.systemBlue {
        didSet { lasso.strokeColor = color.cgColor }
    }
}
