import Foundation
import QuartzCore

/// The engine's display link. Runs at 120 Hz only while something is moving (ink under the Pencil, or
/// the viewport changed within the last ``scrollLinger`` s) and pauses otherwise, so an idle page
/// costs nothing. Also delivers one-off redraws (`requestFrame`) on the next vsync.
///
/// Live-stroke frames are not drawn here: they are drawn inside the touch event (lowest latency);
/// while ink is live, the link just holds the display at 120 Hz.
@MainActor
final class FrameDriver {
    /// Why the link must run at full rate.
    enum Reason: Hashable {
        case ink, scroll
    }

    /// Keep 120 Hz this long after the last viewport change (deceleration frames arrive as more changes).
    var scrollLinger: CFTimeInterval = 0.25

    private var link: CADisplayLink?
    private var reasons: Set<Reason> = []
    private var lastScroll: CFTimeInterval = 0
    private var needsFrame = false
    private let draw: @MainActor () -> Void

    /// `draw` renders a frame when one was requested.
    init(draw: @escaping @MainActor () -> Void) {
        self.draw = draw
    }

    /// The link is running (tests).
    var isRunning: Bool {
        link.map { !$0.isPaused } ?? false
    }

    /// Whether `reason` is active.
    func isActive(_ reason: Reason) -> Bool {
        reasons.contains(reason)
    }

    /// Ink began/ended.
    func setInkActive(_ active: Bool) {
        if active {
            reasons.insert(.ink)
        } else {
            reasons.remove(.ink)
        }
        update()
    }

    /// The viewport moved: high rate for a short while, and redraw.
    func viewportDidChange() {
        reasons.insert(.scroll)
        lastScroll = CACurrentMediaTime()
        requestFrame()
    }

    /// Draws on the next vsync.
    func requestFrame() {
        needsFrame = true
        update()
    }

    /// Stops the link for good.
    func invalidate() {
        link?.invalidate()
        link = nil
    }

    private func update() {
        let shouldRun = needsFrame || !reasons.isEmpty
        if shouldRun, link == nil {
            let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        link?.isPaused = !shouldRun
    }

    fileprivate func tick(_ timestamp: CFTimeInterval) {
        if reasons.contains(.scroll), timestamp - lastScroll > scrollLinger {
            reasons.remove(.scroll)
        }
        if needsFrame {
            needsFrame = false
            draw()
        }
        update()
    }
}

/// Weak trampoline: `CADisplayLink` retains its target.
private final class LinkTarget: NSObject {
    private weak var driver: FrameDriver?

    @MainActor
    init(_ driver: FrameDriver) {
        self.driver = driver
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        guard let driver else {
            link.invalidate()
            return
        }
        driver.tick(link.timestamp)
    }
}
