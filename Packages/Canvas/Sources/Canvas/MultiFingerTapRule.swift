import Foundation

/// When a two- or three-finger tap on the canvas counts (#121, ``MultiFingerTaps``): quick, the fingers
/// didn't scroll or zoom (and didn't land to stop a fling), and no Pencil was on or near the glass (a palm
/// and a finger shouldn't undo mid-sentence). Times are touch timestamps (seconds since boot).
public struct MultiFingerTapRule: Sendable {
    /// Longest first-touch-to-lift time that's still a tap (s).
    public static let maximumDuration: TimeInterval = 0.3
    /// Fingers landing this soon after a Pencil lift are a palm, not a tap (s).
    public static let pencilQuietPeriod: TimeInterval = 0.5

    /// Pencil touches currently down.
    public var pencilsDown = 0
    /// When the last Pencil touch lifted.
    public var lastPencilUp: TimeInterval = -.infinity

    public init(pencilsDown: Int = 0, lastPencilUp: TimeInterval = -.infinity) {
        self.pencilsDown = pencilsDown
        self.lastPencilUp = lastPencilUp
    }

    /// Whether a tap whose first finger landed at `began` and whose fingers lifted at `ended` counts.
    /// `navigated`: the touch sequence scrolled, zoomed, or landed on a moving canvas.
    public func accepts(began: TimeInterval, ended: TimeInterval, navigated: Bool) -> Bool {
        pencilsDown == 0
            && !navigated
            && ended - began <= Self.maximumDuration
            && began - lastPencilUp >= Self.pencilQuietPeriod
    }
}
