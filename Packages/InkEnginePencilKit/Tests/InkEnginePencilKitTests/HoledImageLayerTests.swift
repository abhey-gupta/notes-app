import CoreGraphics
@testable import InkEnginePencilKit
import Testing

/// The mask-free ink hole (#44): bands cover the bounds minus the hole, each showing its part of the image.
@MainActor
struct HoledImageLayerTests {
    private let bounds = CGRect(x: 0, y: 0, width: 100, height: 200)

    @Test func noHoleIsOneBand() {
        #expect(HoledImageLayer.bands(in: bounds, hole: nil) == [bounds])
        #expect(HoledImageLayer.bands(in: bounds, hole: CGRect(x: 200, y: 0, width: 10, height: 10)) == [bounds])
    }

    @Test func middleHoleIsFourBands() {
        let bands = HoledImageLayer.bands(in: bounds, hole: CGRect(x: 10, y: 50, width: 80, height: 100))
        #expect(bands == [
            CGRect(x: 0, y: 0, width: 100, height: 50),
            CGRect(x: 0, y: 150, width: 100, height: 50),
            CGRect(x: 0, y: 50, width: 10, height: 100),
            CGRect(x: 90, y: 50, width: 10, height: 100),
        ])
    }

    @Test func fullWidthHoleLeavesTopAndBottom() {
        let bands = HoledImageLayer.bands(in: bounds, hole: CGRect(x: 0, y: 34, width: 100, height: 120))
        #expect(bands == [CGRect(x: 0, y: 0, width: 100, height: 34), CGRect(x: 0, y: 154, width: 100, height: 46)])
    }

    @Test func holeOverEverythingShowsNothing() {
        #expect(HoledImageLayer.bands(in: bounds, hole: bounds.insetBy(dx: -5, dy: -5)).isEmpty)
    }

    @Test func bandsShowTheirPartOfTheImage() {
        let layer = HoledImageLayer()
        layer.frame = bounds
        layer.hole = CGRect(x: 0, y: 50, width: 100, height: 100)
        layer.layoutIfNeeded()
        #expect(layer.bandFrames == [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 0, y: 150, width: 100, height: 50)])
        let rects = layer.sublayers?.filter { !$0.isHidden }.map(\.contentsRect)
        #expect(rects == [CGRect(x: 0, y: 0, width: 1, height: 0.25), CGRect(x: 0, y: 0.75, width: 1, height: 0.25)])
    }
}
