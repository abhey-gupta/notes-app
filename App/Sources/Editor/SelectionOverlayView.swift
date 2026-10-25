import Canvas
import InkEngine
import Tools
import UIKit

/// Lasso selection chrome over the canvas (ARCHITECTURE.md §6): marching-ants hull, four corner handles,
/// and the drag that moves (inside the hull) or resizes (from a corner) the selection.
///
/// Claims only touches on the selection (hull box or a handle), Pencil or finger, so everything else
/// reaches the engine and the scroll view; while it tracks one, the scroll view's pan stays out. Drags
/// report a page-space transform each frame (``onDrag``); `SelectionMachine` lifts the ink with it and
/// bakes it on release. The overlay only draws the selection it is given; geometry follows the viewport on
/// every scroll/zoom frame.
@MainActor
final class SelectionOverlayView: UIView, CanvasOverlay {
    enum DragPhase {
        case changed, ended, cancelled
    }

    /// The selection to draw, `nil` for none.
    var selection: LassoSelection? {
        didSet {
            if selection == nil {
                cancelDrag()
            }
            update()
        }
    }

    /// Selection outline color (paper dependent).
    var tint = UIColor.systemBlue {
        didSet { applyTint() }
    }

    /// A drag wants to start on `corner` (`nil` = move). Return `false` to refuse it (an edit in flight).
    var onDragBegan: (LassoSelection.Corner?) -> Bool = { _ in true }
    /// Page-space transform of the drag so far.
    var onDrag: (DragPhase, CGAffineTransform) -> Void = { _, _ in }
    /// View-space frame of the selection box for the context bar; `nil` when hidden or mid-drag.
    var onFrameChange: (CGRect?) -> Void = { _ in }
    /// A finger tap on the canvas off the selection (Pencil taps off it start a new lasso instead).
    var onTapOutside: () -> Void = {}

    /// Touch slop around the hull box and handle hit radius (pt, view space).
    private static let slop: CGFloat = 10
    private static let handleHitRadius: CGFloat = 24
    private static let handleRadius: CGFloat = 6

    private var viewport = Viewport.empty
    private var drag: (corner: LassoSelection.Corner?, transform: CGAffineTransform)?
    private let ants = CAShapeLayer()
    private let antsUnderlay = CAShapeLayer()
    private let handles = (0 ..< 4).map { _ in CAShapeLayer() }
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    private var lastReportedFrame: CGRect??

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        antsUnderlay.fillColor = nil
        antsUnderlay.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
        antsUnderlay.lineWidth = 2.5
        antsUnderlay.lineJoin = .round
        ants.fillColor = UIColor.systemBlue.withAlphaComponent(0.04).cgColor
        ants.lineWidth = 1.25
        ants.lineJoin = .round
        ants.lineDashPattern = [6, 4]
        layer.addSublayer(antsUnderlay)
        layer.addSublayer(ants)
        for handle in handles {
            handle.fillColor = UIColor.white.cgColor
            handle.lineWidth = 1.5
            handle.shadowColor = UIColor.black.cgColor
            handle.shadowOpacity = 0.18
            handle.shadowRadius = 2
            handle.shadowOffset = CGSize(width: 0, height: 1)
            layer.addSublayer(handle)
        }
        applyTint()
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: CanvasOverlay

    func canvasHost(_: CanvasHostView, didUpdate viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        update()
    }

    /// Whether `point` (view space) is on the selection: the hull box (plus slop) or a handle.
    func claims(_ point: CGPoint) -> Bool {
        guard let box = viewBox(of: selection) else { return false }
        return box.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) || corner(at: point) != nil
    }

    // MARK: UIView

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        drag != nil || claims(point)
    }

    /// Keeps the scroll view (and other ancestors' pans) from starting on a touch that moves the selection.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === pan {
            return selection != nil
        }
        return !(recognizer is UIPanGestureRecognizer)
    }

    /// The outside-tap recognizer sits on the scroll view (touches off the selection never reach this view).
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        tap.view?.removeGestureRecognizer(tap)
        tap.cancelsTouchesInView = false
        tap.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        superview?.addGestureRecognizer(tap)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        animateAnts()
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard selection != nil, drag == nil, !claims(recognizer.location(in: self)) else { return }
        onTapOutside()
    }

    // MARK: Drag

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let zoom = max(viewport.zoomScale, 0.01)
        let delta = recognizer.translation(in: self)
        let translation = CGSize(width: delta.x / zoom, height: delta.y / zoom)
        switch recognizer.state {
        case .began:
            let start = CGPoint(x: recognizer.location(in: self).x - delta.x, y: recognizer.location(in: self).y - delta.y)
            let corner = corner(at: start)
            guard selection != nil, onDragBegan(corner) else {
                recognizer.isEnabled = false // cancels it
                recognizer.isEnabled = true
                return
            }
            drag = (corner, .identity)
            fallthrough
        case .changed:
            guard let selection, let current = drag else { return }
            let transform = current.corner.map { selection.resizeTransform(dragging: $0, by: translation) }
                ?? CGAffineTransform(translationX: translation.width, y: translation.height)
            drag = (current.corner, transform)
            update()
            onDrag(.changed, transform)
        case .ended:
            finishDrag(.ended)
        case .cancelled, .failed:
            finishDrag(.cancelled)
        default:
            break
        }
    }

    private func finishDrag(_ phase: DragPhase) {
        guard let current = drag else { return }
        drag = nil
        // A drop comes back as the selection shown at the drop point.
        onDrag(phase, phase == .ended ? current.transform : .identity)
        update()
    }

    private func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        pan.isEnabled = false // cancels the gesture; `finishDrag` sees no drag
        pan.isEnabled = true
    }

    // MARK: Drawing

    private func displayed() -> LassoSelection? {
        guard let selection else { return nil }
        return drag.map { selection.applying($0.transform) } ?? selection
    }

    private func pageToView(_ selection: LassoSelection?) -> CGAffineTransform? {
        guard let selection, let page = viewport.page(selection.pageID) else { return nil }
        return viewport.pageToView(page)
    }

    private func viewBox(of selection: LassoSelection?) -> CGRect? {
        guard let selection = selection.flatMap({ s in drag.map { s.applying($0.transform) } ?? s }),
              let transform = pageToView(selection) else { return nil }
        return selection.bounds.applying(transform)
    }

    private func corner(at point: CGPoint) -> LassoSelection.Corner? {
        guard let selection = displayed(), let transform = pageToView(selection) else { return nil }
        let hits = LassoSelection.Corner.allCases.map { corner in
            let p = selection.point(of: corner).applying(transform)
            return (corner, hypot(p.x - point.x, p.y - point.y))
        }
        guard let nearest = hits.min(by: { $0.1 < $1.1 }), nearest.1 <= Self.handleHitRadius else { return nil }
        return nearest.0
    }

    /// Redraws hull and handles for the current selection, drag and viewport (cheap: a hull path and four dots).
    private func update() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let selection = displayed(), let transform = pageToView(selection) else {
            ants.path = nil
            antsUnderlay.path = nil
            handles.forEach { $0.path = nil }
            reportFrame(nil)
            return
        }
        let hull = CGMutablePath()
        hull.addLines(between: selection.hull.map { $0.applying(transform) })
        hull.closeSubpath()
        ants.path = hull
        antsUnderlay.path = hull
        for (handle, corner) in zip(handles, LassoSelection.Corner.allCases) {
            let p = selection.point(of: corner).applying(transform)
            let r = Self.handleRadius
            handle.path = UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).cgPath
        }
        reportFrame(drag == nil ? selection.bounds.applying(transform) : nil)
    }

    private func reportFrame(_ frame: CGRect?) {
        guard lastReportedFrame != .some(frame) else { return }
        lastReportedFrame = .some(frame)
        onFrameChange(frame)
    }

    private func applyTint() {
        ants.strokeColor = tint.cgColor
        ants.fillColor = tint.withAlphaComponent(0.04).cgColor
        for handle in handles {
            handle.strokeColor = tint.cgColor
        }
    }

    private func animateAnts() {
        guard window != nil, ants.animation(forKey: "march") == nil else { return }
        let march = CABasicAnimation(keyPath: "lineDashPhase")
        march.fromValue = 0
        march.toValue = -10
        march.duration = 0.6
        march.repeatCount = .infinity
        ants.add(march, forKey: "march")
    }
}

extension SelectionOverlayView: UIGestureRecognizerDelegate {
    /// The scroll view's pan waits for the selection drag to fail (it only can on a claimed touch).
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        recognizer === pan && other is UIPanGestureRecognizer && other.view !== self
    }
}
