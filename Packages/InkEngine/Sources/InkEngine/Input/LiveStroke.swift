import CoreGraphics
import Foundation
import InkModel

/// The stroke under the Pencil: touch records → page-space ``InkModel/Sample``s (ARCHITECTURE.md §3.2).
///
/// - Coalesced touches append to ``samples``.
/// - Predicted touches replace ``predicted``, a discardable tail drawn after the samples and thrown
///   away on the next event.
/// - Estimated properties (force, altitude, azimuth, location) are patched in place when UIKit
///   delivers their final values, matched by `estimationUpdateIndex`.
public struct LiveStroke: Sendable {
    /// Touch sequence driving this stroke.
    public let touch: TouchID
    /// Input device (Pencil, or finger when finger drawing is on).
    public let device: TouchRecord.Kind
    /// Page the stroke is on.
    public let page: PageID
    /// View → page transform captured at pen-down (the viewport doesn't move under the Pencil).
    public let viewToPage: CGAffineTransform
    /// Timestamp of the first sample (`t = 0`).
    public let startTimestamp: TimeInterval
    /// Committed samples in page space.
    public private(set) var samples: [Sample] = []
    /// Predicted tail in page space, replaced every event.
    public private(set) var predicted: [Sample] = []
    /// Timestamp of the newest coalesced touch (for pen-to-pixel latency).
    public private(set) var latestTimestamp: TimeInterval

    private struct Pending {
        var index: Int
        var expecting: TouchRecord.Properties
    }

    private var pending: [Int: Pending] = [:]
    private let rotation: Float
    /// Samples carry the Pencil's force; off (pressure toggle, #123) records ``InkModel/Sample/neutralForce``.
    public let recordsForce: Bool

    /// Starts a stroke at `touch` (its timestamp is `t = 0`) on `page`. Append the first event's
    /// touches with ``append(coalesced:predicted:)``.
    /// - Parameter recordsForce: `false` flattens every sample's force to ``InkModel/Sample/neutralForce``.
    public init(touch: TouchRecord, page: PageID, viewToPage: CGAffineTransform, recordsForce: Bool = true) {
        self.touch = touch.id
        device = touch.kind
        self.page = page
        self.viewToPage = viewToPage
        startTimestamp = touch.timestamp
        latestTimestamp = touch.timestamp
        rotation = Float(atan2(viewToPage.b, viewToPage.a))
        self.recordsForce = recordsForce
    }

    /// Some samples still carry estimated values awaiting an update.
    public var isAwaitingEstimates: Bool {
        !pending.isEmpty
    }

    /// Samples followed by the predicted tail: what to draw this frame.
    public var displaySamples: [Sample] {
        samples + predicted
    }

    /// Appends one event's coalesced touches and replaces the predicted tail.
    public mutating func append(coalesced: [TouchRecord], predicted newPredicted: [TouchRecord]) {
        samples.reserveCapacity(samples.count + coalesced.count)
        for record in coalesced {
            if let index = record.estimationUpdateIndex, !record.estimatedPropertiesExpectingUpdates.isEmpty {
                pending[index] = Pending(index: samples.count, expecting: record.estimatedPropertiesExpectingUpdates)
            }
            samples.append(sample(record))
            latestTimestamp = max(latestTimestamp, record.timestamp)
        }
        predicted = newPredicted.map(sample)
    }

    /// Patches the sample that `record` (from `touchesEstimatedPropertiesUpdated`) refines.
    /// - Returns: The patched sample index, or `nil` if the record matches no pending sample.
    @discardableResult
    public mutating func applyEstimatedUpdate(_ record: TouchRecord) -> Int? {
        guard let updateIndex = record.estimationUpdateIndex, let entry = pending[updateIndex] else { return nil }
        let fresh = sample(record)
        var s = samples[entry.index]
        s.force = fresh.force
        s.altitude = fresh.altitude
        s.azimuth = fresh.azimuth
        if entry.expecting.contains(.location) {
            s.x = fresh.x
            s.y = fresh.y
        }
        samples[entry.index] = s
        if record.estimatedPropertiesExpectingUpdates.isEmpty {
            pending[updateIndex] = nil
        } else {
            pending[updateIndex]?.expecting = record.estimatedPropertiesExpectingUpdates
        }
        return entry.index
    }

    /// Pen lifted: drops the predicted tail. Pending estimates may still be patched afterwards.
    public mutating func finish() {
        predicted = []
    }

    private func sample(_ r: TouchRecord) -> Sample {
        let p = r.location.applying(viewToPage)
        return Sample(
            x: Float(p.x),
            y: Float(p.y),
            force: recordsForce && r.kind == .pencil ? r.normalizedForce : Sample.neutralForce,
            altitude: r.kind == .pencil ? Float(r.altitude) : Sample.perpendicularAltitude,
            azimuth: Float(r.azimuth) + rotation,
            t: Float(r.timestamp - startTimestamp)
        )
    }
}
