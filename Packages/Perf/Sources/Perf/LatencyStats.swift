/// Rolling percentiles over the last `capacity` samples (ring buffer, nearest-rank).
/// Recording is O(1); percentile queries sort a copy, so query at HUD rate, not per sample.
public struct LatencyStats: Sendable {
    public let capacity: Int
    private var samples: [Double] = []
    private var next = 0

    public init(capacity: Int = 240) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        samples.reserveCapacity(capacity)
    }

    public var count: Int {
        samples.count
    }

    public var isEmpty: Bool {
        samples.isEmpty
    }

    public mutating func record(_ sample: Double) {
        if samples.count < capacity {
            samples.append(sample)
        } else {
            samples[next] = sample
        }
        next = (next + 1) % capacity
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
        next = 0
    }

    /// Nearest-rank percentile, `p` in 0...1. Nil when empty.
    public func percentile(_ p: Double) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let rank = Int((min(max(p, 0), 1) * Double(sorted.count)).rounded(.up))
        return sorted[max(rank, 1) - 1]
    }

    public var p50: Double? {
        percentile(0.5)
    }

    public var p95: Double? {
        percentile(0.95)
    }
}
