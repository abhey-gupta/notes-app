import InkEngine
import InkGeometry
import InkModel
import PencilKit
import simd
import UIKit

/// Hold to snap (#165): a pen or highlighter stroke held still for ``shapeHoldDuration`` becomes the perfect
/// shape it was meant to be (``InkGeometry/ShapeRecognizer``). The freehand stroke is cut short and never
/// committed: on a PencilKit canvas its drawing gesture is cancelled and whatever it leaves is dropped
/// (``PageCanvas/discardsStroke``); on the input view (pressure off, highlighter) its live stroke is cancelled.
/// While the Pencil stays down the shape follows it (``InkGeometry/SnapShape/adjusted(anchor:to:)``); lift
/// commits it, at constant width, like a stroke of a pen with pressure off (`+FlatPen`) or a highlight.
///
/// The drawing touch is watched by a ``TouchWatchGesture`` on the engine root, beside whichever view draws it.
extension PencilKitInkEngine {
    /// How long the Pencil must stay still for a stroke to snap.
    static let shapeHoldDuration: TimeInterval = 0.5
    /// How far (screen pt) the Pencil may drift and still count as still.
    static let shapeHoldTolerance: CGFloat = 3

    func setUpShapeSnap() {
        let gesture = shapeSnap.gesture
        gesture.onBegan = { [weak self] in self?.shapeTouchBegan($0) ?? false }
        gesture.onMoved = { [weak self] in self?.shapeTouchMoved($0) }
        gesture.onEnded = { [weak self] cancelled in
            if cancelled {
                self?.cancelShapeSnap()
            } else {
                self?.shapeTouchEnded()
            }
        }
        host.addGestureRecognizer(gesture)
    }

    // MARK: Touch

    /// A touch went down: tracks it if it draws ink.
    /// - Returns: Whether it is tracked.
    @discardableResult
    func shapeTouchBegan(_ touch: TouchRecord) -> Bool {
        guard tool.snapsShapes, tool.penKind != nil, drawsInk(touch.kind),
              let page = viewport.pages.first(where: { $0.frame.contains(touch.location) })
        else { return false }
        cancelShapeSnap()
        let point = Point2(touch.location) - Point2(page.frame.origin)
        shapeSnap.tracking = ShapeTracking(
            page: page.id,
            origin: page.frame.origin,
            points: [point],
            still: point,
            stillSince: touch.timestamp
        )
        shapeSnap.lastTouch = touch
        armShapeHold(after: Self.shapeHoldDuration)
        return true
    }

    /// The touch moved: follows it with the shape once snapped, else records the stroke and restarts the
    /// hold whenever it leaves the tolerance.
    func shapeTouchMoved(_ touches: [TouchRecord]) {
        guard var tracking = shapeSnap.tracking, let last = touches.last else { return }
        shapeSnap.lastTouch = last
        let points = touches.map { Point2($0.location) - Point2(tracking.origin) }
        if var session = shapeSnap.session, let point = points.last {
            session.shape = session.snapped.adjusted(anchor: session.anchor, to: point)
            shapeSnap.session = session
            showShape()
            return
        }
        let tolerance = Float(Self.shapeHoldTolerance / max(viewport.zoomScale, 0.01))
        for (point, touch) in zip(points, touches) where simd_distance(point, tracking.still) > tolerance {
            tracking.still = point
            tracking.stillSince = touch.timestamp
        }
        tracking.points += points
        shapeSnap.tracking = tracking
    }

    /// The touch lifted: commits the shape, if it snapped.
    func shapeTouchEnded() {
        let session = shapeSnap.session
        shapeSnap.reset()
        guard let session else { return }
        let stroke = session.stroke
        if let layer = session.layer {
            commitHighlight(stroke, layer: layer, to: session.page)
        } else {
            commitPen(stroke, to: session.page)
            showFlatPen()
        }
    }

    /// Drops the shape (touch cancelled, tool changed, setting off); the freehand stroke is already gone.
    func cancelShapeSnap() {
        let session = shapeSnap.session
        shapeSnap.reset()
        guard let session else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let layer = session.layer {
            removeLiveBand(layer, on: session.page)
        }
        clearHighlightSpill()
        showFlatPen()
    }

    /// Drops the shape when `newTool` is another tool or has the setting off.
    func cancelShapeSnap(unlessKeptBy newTool: ToolConfiguration) {
        if newTool.tool != tool.tool || !newTool.snapsShapes {
            cancelShapeSnap()
        }
    }

    /// Removes what PencilKit kept of a stroke a snap cut short (``PageCanvas/discardsStroke``): the shape
    /// replaces it. - Returns: Whether `canvas`'s new strokes were such and are gone.
    func dropCutStroke(_ canvas: PageCanvas) -> Bool {
        let extra = canvas.view.drawing.strokes.count - canvas.ids.count
        guard canvas.discardsStroke, extra > 0 else { return false }
        isSettingDrawing = true
        canvas.view.drawing.strokes.removeLast(extra)
        isSettingDrawing = false
        return true
    }

    /// The touch has been still for ``shapeHoldDuration``: snaps the stroke if it reads as a shape.
    func shapeHoldElapsed() {
        guard let tracking = shapeSnap.tracking, shapeSnap.session == nil, let kind = tool.penKind, freehandIsLive(on: tracking.page),
              let shape = ShapeRecognizer.recognize(tracking.points), let anchor = tracking.points.last
        else { return }
        // The freehand band goes and the shape's comes in the same frame: no fade (layers removed or
        // added outside a view animate it by default).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cutFreehand(on: tracking.page)
        let touch = shapeSnap.lastTouch
        let template = usesHighlighter
            ? Highlight.stroke(color: tool.color, width: tool.width, samples: [])
            : Self.flatStroke(kind, color: tool.color, width: tool.width, samples: [])
        var layer: CAShapeLayer?
        if usesHighlighter {
            let band = Highlight.makeLayer()
            pageViews[tracking.page]?.addLiveHighlight(band)
            layer = band
        } else if let settling = selection.flatPenSettlingPage, settling != tracking.page {
            settleFlatPen() // one image, one page
        }
        shapeSnap.session = ShapeSession(
            page: tracking.page, snapped: shape, shape: shape, anchor: anchor, template: template, layer: layer,
            altitude: Float(touch?.altitude ?? .pi / 2), azimuth: Float(touch?.azimuth ?? 0)
        )
        showShape()
    }

    // MARK: Drawing

    /// Draws the shape: the highlighter's band, or the pen's image in `selection.flatPen`.
    private func showShape() {
        guard let session = shapeSnap.session else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let layer = session.layer {
            let stroke = session.stroke
            Highlight.configure(layer, stroke: stroke, color: highlightColor(stroke))
            showHighlightSpill(stroke, from: session.page)
        } else {
            showFlatPen()
        }
    }

    /// Re-checks the hold when it may have elapsed: after `delay`, or later if the touch moved meanwhile.
    private func armShapeHold(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let tracking = shapeSnap.tracking, shapeSnap.session == nil else { return }
            let remaining = tracking.stillSince + Self.shapeHoldDuration - CACurrentMediaTime()
            if remaining > 0.01 {
                armShapeHold(after: remaining)
            } else {
                shapeHoldElapsed()
            }
        }
    }

    /// The touch kind draws ink with the current settings (as ``InkEngine/InputPolicy`` and the canvases' drawing policy).
    func drawsInk(_ kind: TouchRecord.Kind) -> Bool {
        kind == .pencil || (kind == .direct && tool.allowsFingerDrawing && !hasSeenPencil)
    }

    /// A freehand stroke is being drawn on `page` right now.
    private func freehandIsLive(on page: PageID) -> Bool {
        if usesHighlighter {
            return selection.liveHighlight?.page == page
        }
        if usesFlatPen {
            return selection.flatPenLive?.page == page
        }
        return canvas(for: page)?.isUsingTool == true
    }

    /// Ends the freehand stroke on `page` without committing it.
    private func cutFreehand(on page: PageID) {
        if drawsThroughInput {
            input.cancelActiveStroke()
            // Whatever the input view had in progress, the engine draws no freehand stroke from here on.
            selection.flatPenLive = nil
            selection.flatPenStroke = nil
            cancelLiveHighlight()
        } else if let canvas = canvas(for: page) {
            hideCrossPageInk()
            canvas.discardsStroke = true
            // Cancels PencilKit's stroke; the touch stays with this engine's gesture.
            canvas.view.drawingGestureRecognizer.isEnabled = false
            canvas.view.drawingGestureRecognizer.isEnabled = true
        }
    }
}

// MARK: - State

/// Hold-to-snap state: the touch being watched and, once snapped, the shape following it.
@MainActor
final class ShapeSnap {
    let gesture = TouchWatchGesture()
    var tracking: ShapeTracking?
    var session: ShapeSession?
    /// The newest touch record (tilt for the shape's samples).
    var lastTouch: TouchRecord?

    func reset() {
        tracking = nil
        session = nil
        lastTouch = nil
    }
}

/// The stroke so far in page space, and where and since when the touch has been still.
struct ShapeTracking {
    let page: PageID
    /// The page's origin in engine (content) space.
    let origin: CGPoint
    var points: [Point2]
    var still: Point2
    var stillSince: TimeInterval
}

/// A snapped shape while the Pencil stays down.
struct ShapeSession {
    let page: PageID
    /// The shape as recognized, and as adjusted since.
    let snapped: SnapShape
    var shape: SnapShape
    /// Where the Pencil was when the shape snapped.
    let anchor: Point2
    /// The stroke it commits as (ID, seed, pen, color, width).
    let template: Stroke
    /// The highlighter's live band; `nil` for pens (drawn in `selection.flatPen`).
    let layer: CAShapeLayer?
    let altitude: Float
    let azimuth: Float

    /// The shape as the stroke it commits as: its outline at neutral force, the snap's tilt throughout.
    @MainActor var stroke: Stroke {
        let samples = shape.outline().enumerated().map { i, p in
            Sample(x: p.x, y: p.y, altitude: altitude, azimuth: azimuth, t: Float(i) * 0.004)
        }
        return Highlight.isHighlight(template)
            ? Highlight.stroke(template, samples: samples)
            : PencilKitInkEngine.flatStroke(template, samples: samples)
    }
}
