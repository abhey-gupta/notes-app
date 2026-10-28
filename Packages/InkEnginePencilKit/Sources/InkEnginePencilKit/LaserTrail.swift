import CoreGraphics
import Foundation

/// The laser pointer's trail (#159): tip positions in content space with the time each was reached. A point
/// lives ``lifetime`` seconds and fades out over it, so the tail thins away while the Pencil moves and the
/// whole trail is gone that long after lift. Pure, so the fade is testable without a display link.
struct LaserTrail {
    /// How long a point stays visible.
    static let lifetime: TimeInterval = 0.6
    /// Opacity steps the trail is drawn in (one shape layer each).
    static let bands = 8

    /// A run of the trail drawn at one opacity.
    struct Band: Equatable {
        var points: [CGPoint]
        var opacity: Float
    }

    private(set) var points: [(point: CGPoint, time: TimeInterval)] = []

    var isEmpty: Bool {
        points.isEmpty
    }

    /// Adds the tip at `time`; skips moves under a quarter point (a resting tip adds nothing).
    mutating func append(_ point: CGPoint, at time: TimeInterval) {
        if let last = points.last?.point, hypot(point.x - last.x, point.y - last.y) < 0.25 {
            points[points.count - 1].time = max(points[points.count - 1].time, time)
            return
        }
        points.append((point, time))
    }

    mutating func removeAll() {
        points.removeAll()
    }

    /// Drops points older than ``lifetime`` at `now`, keeping the newest expired one while a younger point
    /// follows it, so the tail fades from where it was rather than jumping.
    mutating func prune(now: TimeInterval) {
        guard let firstLive = points.firstIndex(where: { now - $0.time < Self.lifetime }) else {
            points.removeAll()
            return
        }
        points.removeFirst(max(firstLive - 1, 0))
    }

    /// The trail at `now` in ``bands`` runs, oldest first. Each run starts at the previous run's last
    /// point, so the line is unbroken; opacity falls linearly with age.
    func bands(now: TimeInterval) -> [Band] {
        guard points.count > 1 else { return [] }
        var bands = [[CGPoint]](repeating: [], count: Self.bands)
        var previous: (band: Int, point: CGPoint)?
        for (point, time) in points {
            let age = min(max(now - time, 0), Self.lifetime)
            let band = min(Int(age / Self.lifetime * Double(Self.bands)), Self.bands - 1)
            if let previous, previous.band != band {
                bands[band].append(previous.point)
            }
            bands[band].append(point)
            previous = (band, point)
        }
        return bands.indices.reversed().compactMap { band in
            guard bands[band].count > 1 else { return nil }
            return Band(points: bands[band], opacity: 1 - (Float(band) + 0.5) / Float(Self.bands))
        }
    }
}
