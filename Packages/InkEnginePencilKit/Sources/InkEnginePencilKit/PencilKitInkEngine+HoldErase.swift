import InkEngine
import InkGeometry
import InkModel
import simd
import UIKit

/// Hold to erase (#211): a pen or highlighter touch held still where it went down for ``eraseHoldDuration``
/// becomes the eraser for the rest of the touch. The dot drawn so far is cut (as a shape snap cuts its stroke)
/// and the delegate switches the tool (``InkEngineDelegate/engineDidHoldToErase(_:)``); once the eraser arrives
/// (``setTool(_:)``) the touch erases from where it went down, through the input view's eraser path
/// (`+Input`), so it shows the eraser cursor and erases across pages like any eraser stroke.
///
/// The touch is watched by a ``TouchWatchGesture`` on the engine root, beside whichever view draws it.
extension PencilKitInkEngine {
    /// How long the Pencil must stay still where it went down to turn into the eraser.
    static let eraseHoldDuration: TimeInterval = 0.6
    /// How far (screen pt) the Pencil may drift from where it went down and still count as still.
    static let eraseHoldTolerance: CGFloat = 4

    func setUpHoldErase() {
        let gesture = holdErase.gesture
        gesture.onBegan = { [weak self] in self?.holdTouchBegan($0) ?? false }
        gesture.onMoved = { [weak self] in self?.holdTouchMoved($0) }
        gesture.onEnded = { [weak self] in self?.holdTouchEnded(cancelled: $0) }
        host.addGestureRecognizer(gesture)
    }

    // MARK: Touch

    /// A touch went down: watches it if it draws ink.
    /// - Returns: Whether it is watched.
    @discardableResult
    func holdTouchBegan(_ touch: TouchRecord) -> Bool {
        guard tool.holdsToErase, tool.penKind != nil, drawsInk(touch.kind),
              let page = viewport.pages.first(where: { $0.frame.contains(touch.location) })
        else { return false }
        holdErase.reset()
        holdErase.start = touch
        holdErase.page = page.id
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.eraseHoldDuration) { [weak self] in
            guard let self, holdErase.start?.id == touch.id, holdErase.start?.timestamp == touch.timestamp else { return }
            holdElapsed()
        }
        return true
    }

    /// The touch moved: erases along it once the eraser is in, waits for it while held, else stops watching
    /// once it leaves the tolerance.
    func holdTouchMoved(_ touches: [TouchRecord]) {
        guard let start = holdErase.start else { return }
        switch holdErase.phase {
        case .waiting:
            let tolerance = Float(Self.eraseHoldTolerance / max(viewport.zoomScale, 0.01))
            if touches.contains(where: { simd_distance(Point2($0.location), Point2(start.location)) > tolerance }) {
                holdErase.reset()
            }
        case .held:
            holdErase.moves += touches
        case var .erasing(stroke):
            stroke.append(coalesced: touches, predicted: [])
            holdErase.phase = .erasing(stroke)
            inkInputView(input, didProduce: .updated(stroke))
        }
    }

    /// The touch lifted (or was cancelled): ends the eraser stroke, if it began.
    func holdTouchEnded(cancelled: Bool) {
        let phase = holdErase.phase
        holdErase.reset()
        guard case var .erasing(stroke) = phase else { return }
        if cancelled {
            inkInputView(input, didProduce: .cancelled(stroke))
        } else {
            stroke.resolvePendingEstimates()
            inkInputView(input, didProduce: .ended(stroke))
        }
    }

    /// The touch has been still for ``eraseHoldDuration``: cuts its ink and asks for the eraser.
    func holdElapsed() {
        guard case .waiting = holdErase.phase, let page = holdErase.page else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cancelShapeSnap() // a dot never snaps; this stops watching the touch for a shape too
        if freehandIsLive(on: page) {
            cutFreehand(on: page)
        }
        holdErase.phase = .held
        delegate?.engineDidHoldToErase(self)
        beginHoldErasingIfReady()
    }

    /// The eraser is in (``setTool(_:)``): the held touch starts erasing, with every move since the hold.
    func beginHoldErasingIfReady() {
        guard case .held = holdErase.phase, tool.tool == .eraser, let start = holdErase.start,
              let target = inkInputView(input, targetAt: start.location)
        else { return }
        var stroke = LiveStroke(touch: start, page: target.page, viewToPage: target.viewToPage)
        stroke.append(coalesced: [start] + holdErase.moves, predicted: [])
        holdErase.moves = []
        holdErase.phase = .erasing(stroke)
        inkInputView(input, didProduce: .began(stroke))
    }

    /// Stops a held touch from erasing when `newTool` is neither the eraser it waits for nor the one it erases with.
    func cancelHoldErase(unlessKeptBy newTool: ToolConfiguration) {
        switch holdErase.phase {
        case .waiting where newTool.tool != tool.tool || !newTool.holdsToErase:
            holdErase.reset()
        case .erasing where newTool.tool != .eraser:
            holdTouchEnded(cancelled: false)
        default:
            break
        }
    }
}

// MARK: - State

/// Hold-to-erase state: the touch being watched and, once held, its eraser stroke.
@MainActor
final class HoldErase {
    enum Phase {
        /// Watching for the touch to stay still.
        case waiting
        /// Held: waiting for the eraser.
        case held
        /// Erasing along the touch.
        case erasing(LiveStroke)
    }

    let gesture = TouchWatchGesture()
    /// Where and when the watched touch went down; `nil` when none is watched.
    var start: TouchRecord?
    /// The page it went down on.
    var page: PageID?
    var phase = Phase.waiting
    /// Moves while ``Phase/held``, replayed when erasing begins.
    var moves: [TouchRecord] = []

    func reset() {
        start = nil
        page = nil
        phase = .waiting
        moves = []
    }
}
