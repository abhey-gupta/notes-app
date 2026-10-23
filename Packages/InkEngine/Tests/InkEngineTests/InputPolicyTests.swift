import CoreGraphics
@testable import InkEngine
import Testing

func finger(_ id: UInt, t: Double, radius: CGFloat = 10, at point: CGPoint = CGPoint(x: 300, y: 300)) -> TouchRecord {
    TouchRecord(
        id: TouchID(id), kind: .direct, location: point, timestamp: t,
        force: 0, maximumPossibleForce: 0, majorRadius: radius
    )
}

struct PalmRejection {
    @Test func pencilDraws() {
        var policy = InputPolicy()
        #expect(policy.began(pen(0, 0, t: 0)) == .draw)
        #expect(policy.hasSeenPencil)
        #expect(policy.isPencilActive)
        policy.ended(pen(0, 0, t: 1))
        #expect(!policy.isPencilActive)
    }

    @Test func fingerNavigatesByDefault() {
        var policy = InputPolicy()
        #expect(policy.began(finger(2, t: 0)) == .navigate)
    }

    @Test func fingerDrawsOnlyWithSettingAndBeforeAPencilIsSeen() {
        var policy = InputPolicy(allowsFingerDrawing: true)
        #expect(policy.began(finger(2, t: 0)) == .draw)
        policy.ended(finger(2, t: 0.1))
        _ = policy.began(pen(0, 0, t: 1))
        policy.ended(pen(0, 0, t: 2))
        #expect(policy.began(finger(3, t: 5)) == .navigate)
    }

    @Test func fingerWhilePencilDownIsPalm() {
        var policy = InputPolicy(allowsFingerDrawing: true)
        _ = policy.began(pen(0, 0, t: 0))
        #expect(policy.began(finger(2, t: 0.5)) == .palm)
    }

    @Test func fingerWithinWindowAfterPencilLiftIsPalm() {
        var policy = InputPolicy()
        _ = policy.began(pen(0, 0, t: 0))
        policy.ended(pen(0, 0, t: 1))
        #expect(policy.began(finger(2, t: 1.149)) == .palm)
        #expect(policy.began(finger(3, t: 1.151)) == .navigate)
    }

    @Test func largeContactIsPalm() {
        var policy = InputPolicy()
        #expect(policy.began(finger(2, t: 0, radius: 40)) == .palm)
        #expect(policy.began(finger(3, t: 0, radius: 20)) == .navigate)
    }

    @Test func contactThatGrowsIntoPalmIsDemoted() {
        var policy = InputPolicy(allowsFingerDrawing: true)
        #expect(policy.began(finger(2, t: 0, radius: 12)) == .draw)
        #expect(policy.moved(finger(2, t: 0.01, radius: 20)) == .draw)
        #expect(policy.moved(finger(2, t: 0.02, radius: 45)) == .palm)
        #expect(policy.role(of: TouchID(2)) == .palm)
        #expect(policy.moved(finger(2, t: 0.03, radius: 10)) == .palm)
        policy.ended(finger(2, t: 0.04))
        #expect(policy.role(of: TouchID(2)) == nil)
    }

    @Test func pointerNeverDraws() {
        var policy = InputPolicy(allowsFingerDrawing: true)
        let pointer = TouchRecord(id: TouchID(9), kind: .other, location: .zero, timestamp: 0)
        #expect(policy.began(pointer) == .navigate)
    }
}

struct Tracker {
    let target = InkInputTarget(page: page, viewToPage: .identity)

    @Test func pencilStrokeLifecycle() throws {
        var tracker = InkInputTracker()
        var events = tracker.began(pen(0, 0, t: 0), predicted: [pen(2, 0, t: 0.008)]) { _ in target }
        guard case let .began(began) = try #require(events.first) else { Issue.record("expected began"); return }
        #expect(began.samples.count == 1)
        #expect(began.predicted.count == 1)

        events = tracker.moved(pen(4, 0, t: 0.016), coalesced: [pen(2, 0, t: 0.012), pen(4, 0, t: 0.016)])
        guard case let .updated(moved) = try #require(events.first) else { Issue.record("expected updated"); return }
        #expect(moved.samples.count == 3)
        #expect(moved.predicted.isEmpty)

        events = tracker.ended(pen(6, 0, t: 0.02))
        guard case let .ended(done) = try #require(events.first) else { Issue.record("expected ended"); return }
        #expect(done.samples.map(\.x) == [0, 2, 4, 6])
        #expect(tracker.active == nil)
    }

    @Test func offPageTouchIsIgnored() {
        var tracker = InkInputTracker()
        #expect(tracker.began(pen(0, 0, t: 0)) { _ in nil }.isEmpty)
        #expect(tracker.moved(pen(1, 0, t: 0.01)).isEmpty)
    }

    @Test func palmDuringPencilStrokeDoesNotDisturbIt() {
        var tracker = InkInputTracker()
        _ = tracker.began(pen(0, 0, t: 0)) { _ in target }
        #expect(tracker.began(finger(2, t: 0.01, radius: 50)) { _ in target }.isEmpty)
        #expect(tracker.moved(finger(2, t: 0.02, radius: 50)).isEmpty)
        #expect(tracker.active?.touch == pencil)
    }

    @Test func pencilCancelsFingerStroke() {
        var tracker = InkInputTracker(policy: InputPolicy(allowsFingerDrawing: true))
        _ = tracker.began(finger(2, t: 0)) { _ in target }
        #expect(tracker.active?.device == .direct)
        let events = tracker.began(pen(0, 0, t: 0.1)) { _ in target }
        #expect(events.count == 2)
        guard case let .cancelled(cancelled) = events[0] else { Issue.record("expected cancel"); return }
        #expect(cancelled.device == .direct)
        #expect(tracker.active?.device == .pencil)
    }

    @Test func fingerStrokeThatBecomesPalmIsCancelled() throws {
        var tracker = InkInputTracker(policy: InputPolicy(allowsFingerDrawing: true))
        _ = tracker.began(finger(2, t: 0)) { _ in target }
        let events = tracker.moved(finger(2, t: 0.01, radius: 60))
        guard case .cancelled = try #require(events.first) else { Issue.record("expected cancel"); return }
        #expect(tracker.active == nil)
    }

    @Test func endedStrokeWaitsForEstimates() throws {
        var tracker = InkInputTracker()
        _ = tracker.began(pen(0, 0, t: 0, update: 1, expecting: [.force])) { _ in target }
        var events = tracker.ended(pen(5, 0, t: 0.01))
        guard case .updated = try #require(events.first) else { Issue.record("expected hold"); return }
        #expect(tracker.hasFinishingStrokes)

        events = tracker.estimatedPropertiesUpdated(pen(0, 0, t: 0, force: 4, update: 1))
        guard case let .ended(done) = try #require(events.first) else { Issue.record("expected ended"); return }
        #expect(done.samples[0].force == 1)
        #expect(!tracker.hasFinishingStrokes)
    }

    @Test func heldStrokeIsFlushedAfterDeadline() throws {
        var tracker = InkInputTracker()
        _ = tracker.began(pen(0, 0, t: 0, update: 1, expecting: [.force])) { _ in target }
        _ = tracker.ended(pen(5, 0, t: 1))
        #expect(tracker.flush(now: 1.05).isEmpty)
        let events = tracker.flush(now: 1.1)
        guard case .ended = try #require(events.first) else { Issue.record("expected ended"); return }
        #expect(!tracker.hasFinishingStrokes)
    }

    @Test func liveEstimateUpdateEmitsUpdated() throws {
        var tracker = InkInputTracker()
        _ = tracker.began(pen(0, 0, t: 0, force: 1, update: 4, expecting: [.force])) { _ in target }
        let events = tracker.estimatedPropertiesUpdated(pen(0, 0, t: 0, force: 3, update: 4))
        guard case let .updated(live) = try #require(events.first) else { Issue.record("expected updated"); return }
        #expect(live.samples[0].force == 0.75)
    }
}
