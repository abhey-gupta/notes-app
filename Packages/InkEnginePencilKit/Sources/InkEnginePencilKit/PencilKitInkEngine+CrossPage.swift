import InkEngine
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// Ink that runs onto the next page without the Pencil lifting (#163). Pages touch (#162), and a stroke
/// keeps going across the seam: it is drawn over every page it reaches while the Pencil is down, and on
/// lift it is committed as the piece each page keeps (``InkModel/Stroke/pieces(from:across:)``), one undo
/// step. Each piece is shown at once on its page's canvas or as a pending highlight, like any commit.
///
/// While the Pencil is down each drawing path shows the stroke beyond its page its own way:
/// - PencilKit canvases (pens with pressure) only cover their own page. A ``TouchWatchGesture`` follows the
///   stroke and, once it leaves its page, PencilKit renders it into ``CrossPage/layer`` over the other
///   pages (sizes from the pen profile, as for strokes PencilKit didn't draw); the image stays after lift
///   until those pages' canvases have drawn their pieces.
/// - Pens with pressure off already draw into `selection.flatPen`, which now covers every page (`+FlatPen`).
/// - The highlighter (and a highlighter's snapped shape) gets a band in each page view it reaches,
///   ``CrossPage/bands``; page views clip their highlights, so each band shows on its own page only.
extension PencilKitInkEngine {
    /// How long the image of a stroke beyond its page stays after lift if no canvas reports a render.
    static let crossPageRenderCap: TimeInterval = 0.5

    func setUpCrossPage() {
        let layer = crossPage.layer
        layer.anchorPoint = .zero
        layer.contentsGravity = .resize
        layer.isHidden = true
        selection.view.layer.insertSublayer(layer, at: 0)
        let gesture = crossPage.gesture
        gesture.onBegan = { [weak self] in self?.crossPageTouchBegan($0) ?? false }
        gesture.onMoved = { [weak self] in self?.crossPageTouchMoved($0) }
        gesture.onEnded = { [weak self] cancelled in self?.crossPageTouchEnded(cancelled: cancelled) }
        host.addGestureRecognizer(gesture)
    }

    // MARK: Pieces

    /// `stroke`, drawn from `page`, as the piece each visible page keeps.
    func pieces(of stroke: Stroke, from page: PageID) -> [(page: PageID, stroke: Stroke)] {
        stroke.pieces(from: page, across: viewport.pages.map { ($0.id, $0.frame) })
    }

    /// Keeps `stroke` as pending on `page` and draws it on the page's canvas, unless that canvas is mid-stroke.
    /// - Returns: The canvas now drawing it; `nil` if no canvas has it.
    @discardableResult
    func addPending(_ stroke: Stroke, _ pk: PKStroke, to page: PageID) -> PageCanvas? {
        pending[page, default: []].append(PendingStroke(stroke: stroke, pk: pk))
        guard let canvas = canvas(for: page), !canvas.isUsingTool else { return nil }
        isSettingDrawing = true
        canvas.view.drawing.strokes.append(pk)
        isSettingDrawing = false
        canvas.ids.append(stroke.id)
        return canvas
    }

    // MARK: Commits

    /// Reports strokes PencilKit added to `canvas` since the last sync. A stroke that ran onto other pages
    /// (#163) is reported as its pieces: the canvas keeps its own page's, the other pages' go to theirs.
    func absorbCanvasStrokes(_ canvas: PageCanvas) {
        guard let page = canvas.page else { return }
        let strokes = canvas.view.drawing.strokes
        // A stroke a shape snap cut short (`+ShapeSnap`) is dropped, not reported.
        guard strokes.count > canvas.ids.count, !dropCutStroke(canvas) else {
            if strokes.count < canvas.ids.count {
                rebuildCanvas(canvas) // something outside the seam removed strokes; restore the snapshot
            }
            return
        }
        let kind = tool.penKind ?? .ballpoint
        var kept = Array(strokes[..<canvas.ids.count])
        var commits: [[(page: PageID, stroke: Stroke)]] = []
        var elsewhere: [PageCanvas] = []
        for pk in strokes[canvas.ids.count...] {
            let stroke = PencilKitConversion.stroke(from: pk, tool: kind, color: tool.color, width: tool.width)
            let pieces = pieces(of: stroke, from: page)
            commits.append(pieces)
            guard pieces.count > 1 else {
                kept.append(pk)
                canvas.ids.append(stroke.id)
                pending[page, default: []].append(PendingStroke(stroke: stroke, pk: pk))
                continue
            }
            for (piecePage, piece) in pieces {
                let piecePK = PencilKitConversion.pkStroke(from: piece, color: pk.ink.color)
                if piecePage == page {
                    kept.append(piecePK)
                    canvas.ids.append(piece.id)
                    pending[page, default: []].append(PendingStroke(stroke: piece, pk: piecePK))
                } else if let other = addPending(piece, piecePK, to: piecePage) {
                    elsewhere.append(other)
                }
            }
        }
        if commits.contains(where: { $0.count > 1 }) {
            isSettingDrawing = true
            canvas.view.drawing.strokes = kept
            isSettingDrawing = false
            crossPageCommitted(drawnBy: elsewhere)
        }
        for pieces in commits {
            delegate?.engine(self, didCommit: pieces)
        }
    }

    // MARK: Ink image

    /// PencilKit's image of `strokes` (in `page`'s space) in `layer`, over the visible pages they reach but
    /// `excluded`, at screen × zoom resolution; `mask` keeps it off gutters and `excluded` where the image's
    /// rect takes them in. Hides `layer` when there is nothing to show.
    func showInkImage(_ strokes: [Stroke], from page: PageID, in layer: CALayer, mask: CAShapeLayer, excluding excluded: PageID? = nil) {
        guard let start = viewport.page(page), !strokes.isEmpty else {
            hideInkImage(layer)
            return
        }
        let origin = start.frame.origin
        let ink = strokes.reduce(CGRect.null) { $0.union($1.bounds) }.offsetBy(dx: origin.x, dy: origin.y)
        let pages = viewport.pages.filter { $0.id != excluded }.map(\.frame).filter { $0.intersects(ink) }
        let visible = visibleRect.insetBy(dx: -8, dy: -8)
        let rect = pages.reduce(CGRect.null) { $0.union($1.intersection(ink)) }.intersection(visible).integral
        guard !rect.isNull, !rect.isEmpty else {
            layer.isHidden = true
            return
        }
        let screenScale = host.window?.screen.scale ?? host.traitCollection.displayScale
        let scale = min(max(screenScale, 1) * max(viewport.zoomScale, 0.25), maximumRasterDimension / max(rect.width, rect.height))
        let drawing = PKDrawing(strokes: strokes.map { PencilKitConversion.pkStroke(from: $0, color: uiColor($0.color)) })
        var image: CGImage?
        Self.lightTraits.performAsCurrent {
            image = drawing.image(from: rect.offsetBy(dx: -origin.x, dy: -origin.y), scale: scale).cgImage
        }
        layer.contents = image
        layer.frame = rect
        if pages.contains(where: { $0.contains(rect) }) {
            layer.mask = nil
        } else {
            let path = CGMutablePath()
            for frame in pages {
                path.addRect(frame.offsetBy(dx: -rect.minX, dy: -rect.minY))
            }
            mask.path = path
            mask.frame = layer.bounds
            layer.mask = mask
        }
        layer.isHidden = false
    }

    func hideInkImage(_ layer: CALayer) {
        layer.isHidden = true
        layer.contents = nil
    }

    // MARK: PencilKit strokes

    /// A pen touch went down on a page PencilKit draws: follows it.
    func crossPageTouchBegan(_ touch: TouchRecord) -> Bool {
        guard tool.penKind != nil, !drawsThroughInput, drawsInk(touch.kind),
              let page = viewport.pages.first(where: { $0.frame.contains(touch.location) })
        else { return false }
        hideCrossPageInk()
        var live = LiveStroke(
            touch: touch,
            page: page.id,
            viewToPage: CGAffineTransform(translationX: -page.frame.minX, y: -page.frame.minY)
        )
        live.append(coalesced: [touch], predicted: [])
        crossPage.live = live
        crossPage.stroke = StrokeID()
        return true
    }

    func crossPageTouchMoved(_ touches: [TouchRecord]) {
        guard var live = crossPage.live, let page = viewport.page(live.page) else { return }
        live.append(coalesced: touches, predicted: [])
        crossPage.live = live
        if !crossPage.hasLeftPage, touches.contains(where: { !page.frame.contains($0.location) }) {
            crossPage.hasLeftPage = true
        }
        if crossPage.hasLeftPage {
            showCrossPageInk()
        }
    }

    func crossPageTouchEnded(cancelled: Bool) {
        guard crossPage.live != nil else { return }
        crossPage.live = nil
        guard !cancelled, !crossPage.layer.isHidden else {
            hideCrossPageInk()
            return
        }
        settleCrossPageInk()
        let generation = crossPage.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.crossPageRenderCap) { [weak self] in
            guard let self, crossPage.generation == generation else { return }
            hideCrossPageInk()
        }
    }

    /// The live stroke over the pages beyond its own (its own page's canvas draws it there).
    private func showCrossPageInk() {
        guard let live = crossPage.live, let kind = tool.penKind else { return }
        let stroke = Stroke(id: crossPage.stroke, tool: kind, color: tool.color, width: tool.width, samples: live.samples)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        showInkImage([stroke], from: live.page, in: crossPage.layer, mask: crossPage.mask, excluding: live.page)
        CATransaction.commit()
    }

    /// Drops the live stroke's image (a new stroke, a snap cut it short, or its pieces are drawn).
    func hideCrossPageInk() {
        crossPage.live = nil
        crossPage.hasLeftPage = false
        crossPage.awaiting = []
        crossPage.isCommitted = false
        crossPage.generation += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hideInkImage(crossPage.layer)
        CATransaction.commit()
    }

    /// A PencilKit stroke ran onto other pages and was committed: the image stays until `canvases` have drawn
    /// their pieces.
    func crossPageCommitted(drawnBy canvases: [PageCanvas]) {
        crossPage.isCommitted = true
        crossPage.awaiting.formUnion(canvases.compactMap(\.page))
        settleCrossPageInk()
    }

    func crossPageCanvasDidRender(_ canvas: PageCanvas) {
        guard let page = canvas.page, crossPage.awaiting.remove(page) != nil else { return }
        settleCrossPageInk()
    }

    /// Lets the image go once the Pencil is up and the pages it covers draw the stroke themselves.
    private func settleCrossPageInk() {
        guard crossPage.live == nil, crossPage.isCommitted, crossPage.awaiting.isEmpty else { return }
        hideCrossPageInk()
    }

    // MARK: Highlights

    /// Bands of the highlight `stroke` (in `page`'s space, being drawn or snapped) on the other pages it reaches.
    func showHighlightSpill(_ stroke: Stroke, from page: PageID) {
        guard let start = viewport.page(page) else { return }
        let reach = stroke.bounds.offsetBy(dx: start.frame.minX, dy: start.frame.minY)
        for other in viewport.pages where other.id != page && other.frame.intersects(reach) {
            guard let view = pageViews[other.id] else { continue }
            let band = crossPage.bands[other.id] ?? {
                let band = Highlight.makeLayer()
                view.addLiveHighlight(band)
                crossPage.bands[other.id] = band
                return band
            }()
            let moved = stroke.transformed(by: CGAffineTransform(
                translationX: start.frame.minX - other.frame.minX, y: start.frame.minY - other.frame.minY
            ))
            Highlight.configure(band, stroke: moved, color: highlightColor(stroke))
        }
    }

    /// Removes the bands on other pages.
    func clearHighlightSpill() {
        for (page, band) in crossPage.bands {
            removeLiveBand(band, on: page)
        }
        crossPage.bands = [:]
    }

    func removeLiveBand(_ band: CAShapeLayer, on page: PageID) {
        if let view = pageViews[page] {
            view.removeLiveHighlight(band)
        } else {
            band.removeFromSuperlayer()
        }
    }
}

/// State of ink running onto other pages while the Pencil is down (`+CrossPage`, #163).
@MainActor
final class CrossPage {
    /// Follows a stroke PencilKit draws.
    let gesture = TouchWatchGesture()
    /// That stroke so far, in the space of the page it began on.
    var live: LiveStroke?
    /// ID the image renders the live stroke under (its seed and texture).
    var stroke = StrokeID()
    /// The live stroke has been off its page (the image may have something to show).
    var hasLeftPage = false
    /// The stroke beyond its page, over the pages it reached.
    let layer = CALayer()
    let mask = CAShapeLayer()
    /// The stroke was committed; `awaiting` are the pages whose canvases have yet to draw their pieces.
    var isCommitted = false
    var awaiting: Set<PageID> = []
    /// Bumps whenever the image goes; a stale render cap checks it.
    var generation = 0
    /// The live highlight's bands on the other pages it reaches, by page.
    var bands: [PageID: CAShapeLayer] = [:]
}
