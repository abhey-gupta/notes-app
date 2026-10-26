import CoreGraphics
import Foundation
import InkModel

/// Where a drawing touch lands: its page and the view → page transform.
public struct InkInputTarget: Hashable, Sendable {
    /// Page under the touch.
    public var page: PageID
    /// View space → page space.
    public var viewToPage: CGAffineTransform

    /// Creates a target.
    public init(page: PageID, viewToPage: CGAffineTransform) {
        self.page = page
        self.viewToPage = viewToPage
    }
}

/// Engine-independent touch handling (ARCHITECTURE.md §3.2): applies ``InputPolicy`` to every touch
/// and turns the one drawing touch into a ``LiveStroke``. Pure value logic; ``InkInputView`` feeds it
/// from UIKit and engines consume its ``Event``s.
///
/// One stroke at a time. A Pencil touch cancels a finger stroke in progress (never draw with a finger
/// while a Pencil is active). A stroke whose pen lifted while estimates are still pending is held
/// until its updates arrive or ``flush(now:)`` passes ``estimateDeadline``.
public struct InkInputTracker: Sendable {
    /// Output of the tracker.
    public enum Event: Sendable {
        /// A stroke started (first samples appended).
        case began(LiveStroke)
        /// New samples, a new predicted tail, or patched estimates.
        case updated(LiveStroke)
        /// Final samples; commit it.
        case ended(LiveStroke)
        /// Discard it (cancelled touch, palm detected, Pencil took over from a finger).
        case cancelled(LiveStroke)
    }

    /// Touch roles.
    public var policy: InputPolicy
    /// Longest wait after pen-up for estimated property updates (s).
    public var estimateDeadline: TimeInterval = 0.1
    /// New strokes keep the Pencil's force (``LiveStroke/recordsForce``); off for the pressure toggle (#123).
    public var recordsForce = true
    /// The stroke under the Pencil, if any.
    public private(set) var active: LiveStroke?
    private var finishing: [(stroke: LiveStroke, endedAt: TimeInterval)] = []

    /// Creates a tracker.
    public init(policy: InputPolicy = InputPolicy()) {
        self.policy = policy
    }

    /// Ended strokes still waiting for estimate updates.
    public var hasFinishingStrokes: Bool {
        !finishing.isEmpty
    }

    /// `touchesBegan` for one touch.
    /// - Parameters:
    ///   - coalesced: `event.coalescedTouches(for:)`; empty means `[touch]`.
    ///   - target: Page under a view point, or `nil` if the point is off-page (the touch is ignored).
    public mutating func began(
        _ touch: TouchRecord,
        coalesced: [TouchRecord] = [],
        predicted: [TouchRecord] = [],
        target: (CGPoint) -> InkInputTarget?
    ) -> [Event] {
        guard policy.began(touch) == .draw else { return [] }
        var events: [Event] = []
        if let current = active {
            guard touch.kind == .pencil, current.device == .direct else { return [] }
            active = nil
            events.append(.cancelled(current))
        }
        guard let hit = target(touch.location) else { return events }
        let records = coalesced.isEmpty ? [touch] : coalesced
        var stroke = LiveStroke(touch: records[0], page: hit.page, viewToPage: hit.viewToPage, recordsForce: recordsForce)
        stroke.append(coalesced: records, predicted: predicted)
        active = stroke
        events.append(.began(stroke))
        return events
    }

    /// `touchesMoved` for one touch.
    public mutating func moved(_ touch: TouchRecord, coalesced: [TouchRecord] = [], predicted: [TouchRecord] = []) -> [Event] {
        let role = policy.moved(touch)
        guard var current = active, current.touch == touch.id else { return [] }
        guard role == .draw else {
            active = nil
            return [.cancelled(current)]
        }
        current.append(coalesced: coalesced.isEmpty ? [touch] : coalesced, predicted: predicted)
        active = current
        return [.updated(current)]
    }

    /// `touchesEnded` for one touch.
    public mutating func ended(_ touch: TouchRecord, coalesced: [TouchRecord] = []) -> [Event] {
        policy.ended(touch)
        guard var current = active, current.touch == touch.id else { return [] }
        active = nil
        current.append(coalesced: coalesced.isEmpty ? [touch] : coalesced, predicted: [])
        current.finish()
        if current.isAwaitingEstimates {
            finishing.append((current, touch.timestamp))
            return [.updated(current)]
        }
        return [.ended(current)]
    }

    /// `touchesCancelled` for one touch.
    public mutating func cancelled(_ touch: TouchRecord) -> [Event] {
        policy.ended(touch)
        guard let current = active, current.touch == touch.id else { return [] }
        active = nil
        return [.cancelled(current)]
    }

    /// `touchesEstimatedPropertiesUpdated` for one touch: patches the matching sample by
    /// `estimationUpdateIndex`. Completes a held stroke once nothing is pending.
    public mutating func estimatedPropertiesUpdated(_ record: TouchRecord) -> [Event] {
        if var current = active, current.applyEstimatedUpdate(record) != nil {
            active = current
            return [.updated(current)]
        }
        for i in finishing.indices {
            guard finishing[i].stroke.applyEstimatedUpdate(record) != nil else { continue }
            if finishing[i].stroke.isAwaitingEstimates {
                return [.updated(finishing[i].stroke)]
            }
            return [.ended(finishing.remove(at: i).stroke)]
        }
        return []
    }

    /// Completes held strokes whose pen lifted at least ``estimateDeadline`` before `now`.
    public mutating func flush(now: TimeInterval) -> [Event] {
        var events: [Event] = []
        finishing.removeAll { entry in
            guard now - entry.endedAt >= estimateDeadline else { return false }
            events.append(.ended(entry.stroke))
            return true
        }
        return events
    }
}
