import QuartzCore

/// Runs a closure on the next display refresh (one-shot `CADisplayLink`).
@MainActor
final class FrameAfter: NSObject {
    private var action: (() -> Void)?
    private var link: CADisplayLink?

    static func next(_ action: @escaping () -> Void) {
        let frame = FrameAfter()
        frame.action = action
        let link = CADisplayLink(target: frame, selector: #selector(tick))
        frame.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick() {
        link?.invalidate()
        link = nil
        action?()
        action = nil
    }
}
