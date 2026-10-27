import CoreGraphics
@testable import InkGeometry
import InkModel
import Testing

/// The highlighter band (#120): an upright, tall, thin nib swept along the stroke.
struct HighlightBandTests {
    private static func stroke(_ points: [(Float, Float)], height: Float = 20) -> Stroke {
        let samples = points.enumerated().map { i, p in Sample(x: p.0, y: p.1, t: Float(i) / 240) }
        return Stroke(tool: .highlighter, color: .primary, width: height, samples: samples)
    }

    private static func path(_ band: HighlightBand) -> CGPath {
        let path = CGMutablePath()
        for polygon in band.polygons {
            path.addLines(between: polygon.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
            path.closeSubpath()
        }
        return path
    }

    /// Wiggly strokes: every point is in the band exactly when the nib, centered on some centerline
    /// point, covers it (ignoring a thin margin at the edge).
    @Test(arguments: 0 ..< 6)
    func bandIsTheNibSweptAlongTheCenterline(seed: Int) {
        var points: [(Float, Float)] = []
        for i in 0 ..< 80 {
            let t = Float(i) / 79
            let x = 20 + 260 * t + 30 * sin(Float(seed + 1) * 7 * t)
            let y = 100 + 40 * sin(Float(seed + 2) * 5 * t) + 15 * cos(Float(seed) * 11 * t)
            points.append((x, y))
        }
        let stroke = Self.stroke(points)
        let band = HighlightBand(stroke: stroke)
        let centerline = HighlightBand.path(stroke.samples, height: 20)
        let path = Self.path(band)
        let (a, b) = (band.thickness / 2, band.height / 2)
        let margin: Float = 0.6
        var checked = 0
        for gx in stride(from: Float(-10), through: 340, by: 1.7) {
            for gy in stride(from: Float(30), through: 180, by: 1.3) {
                let distance = centerline.map { max(abs(gx - $0.x) - a, abs(gy - $0.y) - b) }.min() ?? .infinity
                guard abs(distance) > margin else { continue }
                let inside = path.contains(CGPoint(x: CGFloat(gx), y: CGFloat(gy)), using: .winding)
                #expect(inside == (distance < 0), "(\(gx), \(gy)) distance \(distance)")
                checked += 1
            }
        }
        #expect(checked > 10000)
    }

    @Test func tremorIsSmoothedAndEndsStayPut() {
        let samples = (0 ... 200).map { i in Sample(x: Float(i), y: 100 + (i % 2 == 0 ? 0.6 : -0.6), t: Float(i) / 240) }
        let path = HighlightBand.path(samples, height: 16)
        let middle = path.filter { $0.x > 20 && $0.x < 180 }
        #expect(middle.allSatisfy { abs($0.y - 100) < 0.25 }, "\(middle.map(\.y).max() ?? 0)")
        #expect(path.first == Point2(0, 100.6))
        #expect(path.last.map { abs($0.x - 200) < 1e-3 } == true)
    }

    @Test func everyPolygonWindsPositively() {
        let band = HighlightBand(stroke: Self.stroke([(0, 0), (50, 30), (100, 0), (60, -40), (0, 10)]))
        #expect(band.polygons.count >= 3)
        for polygon in band.polygons {
            var twiceArea: Float = 0
            for i in polygon.indices {
                let (p, q) = (polygon[i], polygon[(i + 1) % polygon.count])
                twiceArea += p.x * q.y - q.x * p.y
            }
            #expect(twiceArea > 0)
        }
    }

    @Test func sidewaysIsTallWithUprightEndsAndUpwardsIsThin() {
        let sideways = Self.path(HighlightBand(stroke: Self.stroke([(100, 100), (300, 100)])))
        #expect(sideways.boundingBox == CGRect(x: 97.5, y: 90, width: 205, height: 20))
        // Upright ends: full height right up to the end.
        #expect(sideways.contains(CGPoint(x: 302, y: 90.5)) && sideways.contains(CGPoint(x: 302, y: 109.5)))
        let upwards = Self.path(HighlightBand(stroke: Self.stroke([(100, 300), (100, 100)])))
        #expect(upwards.boundingBox == CGRect(x: 97.5, y: 90, width: 5, height: 220))
    }

    /// A hook where the Pencil lands only adds to the band; it never notches the end.
    @Test func hookAtTheStartDoesNotNotchTheEnd() {
        let band = Self.path(HighlightBand(stroke: Self.stroke([(104, 106), (100, 100), (101, 100), (300, 100)])))
        for y in stride(from: CGFloat(90.5), through: 109.5, by: 1) {
            #expect(band.contains(CGPoint(x: 99, y: y)), "y \(y)")
        }
    }

    @Test func dotIsTheNib() {
        let band = HighlightBand(stroke: Self.stroke([(50, 50)], height: 24))
        #expect(Self.path(band).boundingBox == CGRect(x: 47, y: 38, width: 6, height: 24))
        #expect(HighlightBand(stroke: Self.stroke([])).polygons.isEmpty)
    }

    @Test func heightIsTheDrawnWidth() {
        var stroke = Self.stroke([(0, 0), (10, 0)], height: 16)
        #expect(HighlightBand.height(of: stroke) == 16)
        stroke = Stroke(
            tool: .highlighter, color: .primary, width: 16, samples: stroke.samples,
            rendering: StrokeRendering(ink: StrokeRendering.Ink.marker, randomSeed: 1, points: Array(
                repeating: PointRendering(width: 20, height: 20), count: 2
            ))
        )
        #expect(HighlightBand.height(of: stroke) == 1.45 * 20 - 0.5)
    }
}
