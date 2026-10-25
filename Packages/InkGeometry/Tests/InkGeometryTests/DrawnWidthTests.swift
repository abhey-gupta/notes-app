import Foundation
@testable import InkGeometry
import InkModel
import Testing

/// Per-sample drawn widths: round nibs as they are, chisels cut across the stroke's heading.
struct DrawnWidthTests {
    private static func rendering(_ ink: String, size: Float, count: Int) -> StrokeRendering {
        StrokeRendering(ink: ink, randomSeed: 0, points: (0 ..< count).map { _ in PointRendering(width: size, height: size) })
    }

    private static func line(heading: Point2, azimuth: Float, count: Int = 5) -> [Sample] {
        (0 ..< count).map { i in Sample(x: 100 + Float(i) * heading.x, y: 100 + Float(i) * heading.y, azimuth: azimuth, t: Float(i)) }
    }

    @Test func roundNibsIgnoreHeadingAndAzimuth() {
        let rendering = Self.rendering(StrokeRendering.Ink.pen, size: 10, count: 5)
        for azimuth: Float in [0, 1, -2] {
            #expect(rendering.drawnWidths(along: Self.line(heading: Point2(1, 0), azimuth: azimuth)) == [Float](repeating: 16, count: 5))
            #expect(rendering.drawnWidths(along: Self.line(heading: Point2(0, 1), azimuth: azimuth)) == [Float](repeating: 16, count: 5))
        }
    }

    @Test func fountainPenIsThinAlongTheAzimuthAndThickAcross() {
        let rendering = Self.rendering(StrokeRendering.Ink.fountainPen, size: 10, count: 5)
        let thin = rendering.drawnWidths(along: Self.line(heading: Point2(1, 0), azimuth: 0))
        let thick = rendering.drawnWidths(along: Self.line(heading: Point2(0, 1), azimuth: 0))
        #expect(thin.allSatisfy { abs($0 - 4) < 1e-4 })
        #expect(thick.allSatisfy { abs($0 - 16) < 1e-4 })
        // Azimuth is measured from +x toward +y: a nib at +45° lies along the (1, 1) diagonal.
        let diagonal = Point2(1, 1) / Float(2).squareRoot()
        let alongDiagonal = rendering.drawnWidths(along: Self.line(heading: diagonal, azimuth: .pi / 4))
        let acrossDiagonal = rendering.drawnWidths(along: Self.line(heading: diagonal, azimuth: -.pi / 4))
        #expect(alongDiagonal.allSatisfy { abs($0 - 4) < 1e-3 })
        #expect(acrossDiagonal.allSatisfy { abs($0 - 16) < 1e-3 })
        // In between: the ellipse's chord, √((16² + 4²) / 2) ≈ 11.66 (PencilKit measures 11.7).
        let between = rendering.drawnWidths(along: Self.line(heading: Point2(1, 0), azimuth: .pi / 4))
        #expect(between.allSatisfy { abs($0 - 11.66) < 0.01 })
    }

    @Test func headingSkipsDuplicateSamplesAndDotsGetTheWidestSide() {
        let rendering = Self.rendering(StrokeRendering.Ink.fountainPen, size: 10, count: 4)
        // Three coincident samples then one to the right: every sample heads +x (thin side at azimuth 0).
        let samples = [Sample(x: 0, y: 0), Sample(x: 0, y: 0), Sample(x: 0, y: 0), Sample(x: 5, y: 0)]
        #expect(rendering.drawnWidths(along: samples).allSatisfy { abs($0 - 4) < 1e-4 })
        let dot = Self.rendering(StrokeRendering.Ink.fountainPen, size: 10, count: 1)
        #expect(dot.drawnWidths(along: [Sample(x: 0, y: 0)]) == [16])
        #expect(rendering.drawnWidths(along: [Sample(x: 0, y: 0), Sample(x: 0, y: 0)]) == [16, 16])
    }

    @Test func centerlineUsesDrawnWidths() {
        let samples = Self.line(heading: Point2(2, 0), azimuth: 0, count: 20)
        let rendering = Self.rendering(StrokeRendering.Ink.fountainPen, size: 10, count: 20)
        let stroke = Stroke(tool: .fountain, color: .primary, width: 2, samples: samples, rendering: rendering)
        let centerline = Centerline(stroke: stroke)
        #expect(centerline.radii.allSatisfy { abs($0 - 2) < 1e-4 })
        #expect(stroke.intersects(circleCenter: CGPoint(x: 120, y: 103), radius: 1.5))
        #expect(!stroke.intersects(circleCenter: CGPoint(x: 120, y: 104), radius: 1.5))
        #expect(stroke.bounds.contains(centerline.bounds))
    }
}
