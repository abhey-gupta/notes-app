import CoreGraphics
@testable import InkEngine
import InkEngineTestSupport
import InkModel
import Testing

let pencil = TouchID(1)
let page = RenderFixtures.pageID(1)

func pen(
    _ x: CGFloat,
    _ y: CGFloat,
    t: Double,
    force: CGFloat = 2,
    altitude: CGFloat = 1,
    azimuth: CGFloat = 0.5,
    update: Int? = nil,
    expecting: TouchRecord.Properties = []
) -> TouchRecord {
    TouchRecord(
        id: pencil, kind: .pencil, location: CGPoint(x: x, y: y), timestamp: t,
        force: force, maximumPossibleForce: 4, altitude: altitude, azimuth: azimuth,
        estimationUpdateIndex: update, estimatedPropertiesExpectingUpdates: expecting
    )
}

/// View → page: page at view origin (100, 50), zoom 2.
let viewToPage = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 100, ty: 50).inverted()

struct SampleConversion {
    @Test func coalescedTouchesBecomePageSpaceSamples() {
        var stroke = LiveStroke(touch: pen(100, 50, t: 10), page: page, viewToPage: viewToPage)
        stroke.append(coalesced: [pen(100, 50, t: 10), pen(110, 70, t: 10.004), pen(120, 90, t: 10.008)], predicted: [])
        #expect(stroke.samples.count == 3)
        let s = stroke.samples[2]
        #expect(s.x == 10)
        #expect(s.y == 20)
        #expect(s.force == 0.5) // 2 / 4
        #expect(s.altitude == 1)
        #expect(s.azimuth == 0.5)
        #expect(abs(s.t - 0.008) < 1e-6)
        #expect(stroke.samples[0].t == 0)
        #expect(stroke.latestTimestamp == 10.008)
    }

    @Test func predictedTailIsReplacedEachEvent() {
        var stroke = LiveStroke(touch: pen(100, 50, t: 0), page: page, viewToPage: viewToPage)
        stroke.append(coalesced: [pen(100, 50, t: 0)], predicted: [pen(102, 52, t: 0.008), pen(104, 54, t: 0.016)])
        #expect(stroke.predicted.count == 2)
        #expect(stroke.displaySamples.count == 3)
        stroke.append(coalesced: [pen(102, 52, t: 0.008)], predicted: [pen(106, 56, t: 0.016)])
        #expect(stroke.samples.count == 2)
        #expect(stroke.predicted.count == 1)
        #expect(stroke.predicted[0].x == 3)
        stroke.finish()
        #expect(stroke.predicted.isEmpty)
        #expect(stroke.displaySamples == stroke.samples)
    }

    @Test func forceIsNormalizedAndClamped() {
        var stroke = LiveStroke(touch: pen(0, 0, t: 0), page: page, viewToPage: .identity)
        stroke.append(coalesced: [pen(0, 0, t: 0, force: 9), pen(1, 0, t: 0.01, force: 0)], predicted: [])
        #expect(stroke.samples.map(\.force) == [1, 0])
    }

    /// Pressure toggle off (#123): every sample lands at neutral force, estimate updates included.
    @Test func pressureOffRecordsNeutralForce() {
        var stroke = LiveStroke(touch: pen(0, 0, t: 0), page: page, viewToPage: .identity, recordsForce: false)
        stroke.append(
            coalesced: [pen(0, 0, t: 0, force: 4, update: 1, expecting: .force), pen(1, 0, t: 0.01, force: 0)],
            predicted: [pen(2, 0, t: 0.02, force: 3)]
        )
        #expect(stroke.displaySamples.map(\.force) == [0.5, 0.5, 0.5])
        stroke.applyEstimatedUpdate(pen(0, 0, t: 0, force: 3.5, update: 1))
        #expect(stroke.samples[0].force == 0.5)
        #expect(stroke.samples[0].altitude == 1) // tilt still recorded
    }

    @Test func trackerPassesRecordsForceToNewStrokes() {
        var tracker = InkInputTracker()
        tracker.recordsForce = false
        let events = tracker.began(pen(0, 0, t: 0, force: 4)) { _ in InkInputTarget(page: page, viewToPage: .identity) }
        guard case let .began(stroke)? = events.first else {
            Issue.record("no stroke")
            return
        }
        #expect(stroke.recordsForce == false)
        #expect(stroke.samples.map(\.force) == [0.5])
    }

    @Test func fingerSamplesUseNeutralPressureAndUprightAltitude() {
        let finger = TouchRecord(
            id: TouchID(2), kind: .direct, location: .zero, timestamp: 0,
            force: 0, maximumPossibleForce: 0, altitude: 0.3, majorRadius: 10
        )
        var stroke = LiveStroke(touch: finger, page: page, viewToPage: .identity)
        stroke.append(coalesced: [finger], predicted: [])
        #expect(stroke.samples[0].force == Sample.neutralForce)
        #expect(stroke.samples[0].altitude == Sample.perpendicularAltitude)
    }

    @Test func azimuthFollowsViewRotation() {
        let rotate = CGAffineTransform(rotationAngle: 0.25)
        var stroke = LiveStroke(touch: pen(0, 0, t: 0), page: page, viewToPage: rotate)
        stroke.append(coalesced: [pen(0, 0, t: 0, azimuth: 1)], predicted: [])
        #expect(abs(stroke.samples[0].azimuth - 1.25) < 1e-6)
    }
}

struct EstimatedUpdates {
    @Test func patchesForceAltitudeAzimuthByUpdateIndex() {
        var stroke = LiveStroke(touch: pen(100, 50, t: 0), page: page, viewToPage: viewToPage)
        stroke.append(coalesced: [
            pen(100, 50, t: 0, force: 1, update: 7, expecting: [.force, .altitude]),
            pen(110, 60, t: 0.004, force: 1, update: 8, expecting: [.force]),
        ], predicted: [])
        #expect(stroke.isAwaitingEstimates)

        // Final values for the second sample; position is not re-read (location wasn't estimated).
        let patched = stroke.applyEstimatedUpdate(pen(999, 999, t: 0.004, force: 3, altitude: 0.7, azimuth: 2, update: 8))
        #expect(patched == 1)
        let s = stroke.samples[1]
        #expect(s.force == 0.75)
        #expect(s.altitude == Float(CGFloat(0.7)))
        #expect(s.azimuth == 2)
        #expect(s.x == 5)
        #expect(s.y == 5)
        #expect(stroke.isAwaitingEstimates) // index 7 still pending

        // Partial update keeps the entry pending until nothing is expected.
        #expect(stroke.applyEstimatedUpdate(pen(100, 50, t: 0, force: 2, update: 7, expecting: [.altitude])) == 0)
        #expect(stroke.samples[0].force == 0.5)
        #expect(stroke.isAwaitingEstimates)
        #expect(stroke.applyEstimatedUpdate(pen(100, 50, t: 0, force: 2, altitude: 0.5, update: 7)) == 0)
        #expect(!stroke.isAwaitingEstimates)

        // Unknown or already-final indices are ignored.
        #expect(stroke.applyEstimatedUpdate(pen(0, 0, t: 0, update: 7)) == nil)
        #expect(stroke.applyEstimatedUpdate(pen(0, 0, t: 0, update: 99)) == nil)
        #expect(stroke.applyEstimatedUpdate(pen(0, 0, t: 0)) == nil)
    }

    @Test func patchesLocationWhenItWasEstimated() {
        var stroke = LiveStroke(touch: pen(100, 50, t: 0), page: page, viewToPage: viewToPage)
        stroke.append(coalesced: [pen(100, 50, t: 0, update: 1, expecting: [.location])], predicted: [])
        stroke.applyEstimatedUpdate(pen(104, 58, t: 0, update: 1))
        #expect(stroke.samples[0].x == 2)
        #expect(stroke.samples[0].y == 4)
    }

    @Test func touchesWithoutExpectedUpdatesAreNotTracked() {
        var stroke = LiveStroke(touch: pen(0, 0, t: 0), page: page, viewToPage: .identity)
        stroke.append(coalesced: [pen(0, 0, t: 0, update: 3, expecting: [])], predicted: [])
        #expect(!stroke.isAwaitingEstimates)
    }
}
