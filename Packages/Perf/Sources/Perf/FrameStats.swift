/// Frame pacing from display-link callbacks. A hitch is a frame that arrived
/// more than 1.5x the expected interval after the previous one.
public struct FrameStats: Sendable {
    public struct Window: Sendable, Equatable {
        public let averageMs: Double
        public let maxMs: Double
        public var fps: Double {
            averageMs > 0 ? 1000 / averageMs : 0
        }
    }

    public private(set) var hitchCount = 0
    private var lastTimestamp: Double?
    private var windowSum = 0.0
    private var windowMax = 0.0
    private var windowFrames = 0

    public init() {}

    /// `timestamp` / `targetTimestamp` straight from `CADisplayLink` (seconds).
    public mutating func record(timestamp: Double, targetTimestamp: Double) {
        defer { lastTimestamp = timestamp }
        guard let lastTimestamp else { return }
        let delta = timestamp - lastTimestamp
        let expected = targetTimestamp - timestamp
        if expected > 0, delta > expected * 1.5 {
            hitchCount += 1
        }
        windowSum += delta
        windowMax = max(windowMax, delta)
        windowFrames += 1
    }

    /// Returns stats since the last drain and starts a new window.
    public mutating func drainWindow() -> Window? {
        guard windowFrames > 0 else { return nil }
        let window = Window(averageMs: windowSum / Double(windowFrames) * 1000, maxMs: windowMax * 1000)
        windowSum = 0
        windowMax = 0
        windowFrames = 0
        return window
    }

    public mutating func reset() {
        self = FrameStats()
    }
}
