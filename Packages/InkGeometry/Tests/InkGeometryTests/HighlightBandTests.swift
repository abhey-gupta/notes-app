import CoreGraphics
@testable import InkGeometry
import InkModel
import Testing

/// The highlighter band (#120): an upright, tall, thin nib swept along the stroke.
struct HighlightBandTests {
    private static func stroke(_ points: [(Float, Float)], height: Float = 20, nib: HighlighterNib? = nil) -> Stroke {
        let samples = points.enumerated().map { i, p in Sample(x: p.0, y: p.1, t: Float(i) / 240) }
        let plain = Stroke(tool: .highlighter, color: .primary, width: height, samples: samples)
        guard let nib else { return plain }
        var rendering = plain.derivedRendering
        rendering.ink = StrokeRendering.Ink.highlighter(nib)
        return Stroke(tool: .highlighter, color: .primary, width: height, samples: samples, rendering: rendering)
    }

    /// The band's region: its polygons filled, or their outline stroked `2 × cornerRadius` wide.
    private struct Region {
        let fill: CGPath
        let rim: CGPath

        init(_ band: HighlightBand) {
            let path = CGMutablePath()
            for polygon in band.polygons {
                path.addLines(between: polygon.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) })
                path.closeSubpath()
            }
            fill = path
            rim = path.copy(strokingWithWidth: CGFloat(2 * band.cornerRadius), lineCap: .round, lineJoin: .round, miterLimit: 10)
        }

        var boundingBox: CGRect {
            fill.boundingBox.union(rim.boundingBox)
        }

        func contains(_ p: CGPoint) -> Bool {
            fill.contains(p, using: .winding) || rim.contains(p, using: .winding)
        }
    }

    private static func path(_ band: HighlightBand) -> Region {
        Region(band)
    }

    /// Signed distance from `p` to a rounded rectangle centered on `c` (half sizes `a`, `b`, radius `r`).
    private static func distance(_ p: Point2, _ c: Point2, a: Float, b: Float, r: Float) -> Float {
        let q = Point2(abs(p.x - c.x) - (a - r), abs(p.y - c.y) - (b - r))
        return norm(Point2(max(q.x, 0), max(q.y, 0))) + min(max(q.x, q.y), 0) - r
    }

    /// Wiggly strokes: every point is in the band exactly when the nib, centered on some centerline
    /// point, covers it (ignoring a thin margin at the edge).
    @Test(arguments: HighlighterNib.allCases, 0 ..< 6)
    func bandIsTheNibSweptAlongTheCenterline(nib: HighlighterNib, seed: Int) {
        var points: [(Float, Float)] = []
        for i in 0 ..< 80 {
            let t = Float(i) / 79
            let x = 20 + 260 * t + 30 * sin(Float(seed + 1) * 7 * t)
            let y = 100 + 40 * sin(Float(seed + 2) * 5 * t) + 15 * cos(Float(seed) * 11 * t)
            points.append((x, y))
        }
        let stroke = Self.stroke(points, nib: nib)
        let band = HighlightBand(stroke: stroke)
        #expect(band.nib == nib)
        let centerline = HighlightBand.path(stroke.samples, height: 20)
        let path = Self.path(band)
        let (a, b, r) = (band.thickness / 2, band.height / 2, band.cornerRadius)
        let margin: Float = 0.6
        var checked = 0
        for gx in stride(from: Float(-10), through: 340, by: 1.7) {
            for gy in stride(from: Float(30), through: 180, by: 1.3) {
                let distance = centerline.map { Self.distance(Point2(gx, gy), $0, a: a, b: b, r: r) }.min() ?? .infinity
                guard abs(distance) > margin else { continue }
                let inside = path.contains(CGPoint(x: CGFloat(gx), y: CGFloat(gy)))
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
        #expect(sideways.boundingBox.insetBy(dx: -0.01, dy: -0.01).contains(CGRect(x: 97.51, y: 90.01, width: 204.98, height: 19.98)))
        #expect(CGRect(x: 97.49, y: 89.99, width: 205.02, height: 20.02).contains(sideways.boundingBox))
        // Upright ends, corners rounded: full height just inside the end, not at the very corner.
        #expect(sideways.contains(CGPoint(x: 300, y: 90.5)) && sideways.contains(CGPoint(x: 300, y: 109.5)))
        #expect(sideways.contains(CGPoint(x: 302.3, y: 100)))
        #expect(!sideways.contains(CGPoint(x: 302.3, y: 90.3)), "corner rounded off")
        let upwards = Self.path(HighlightBand(stroke: Self.stroke([(100, 300), (100, 100)])))
        #expect(abs(upwards.boundingBox.width - 5) < 0.02 && abs(upwards.boundingBox.height - 220) < 0.02)
    }

    /// A hook where the Pencil lands only adds to the band; it never notches the end.
    @Test func hookAtTheStartDoesNotNotchTheEnd() {
        let band = Self.path(HighlightBand(stroke: Self.stroke([(104, 106), (100, 100), (101, 100), (300, 100)])))
        for y in stride(from: CGFloat(90.5), through: 109.5, by: 1) {
            #expect(band.contains(CGPoint(x: 99, y: y)) || abs(y - 100) > 8.5, "y \(y)")
        }
    }

    @Test func dotIsTheNib() {
        let band = HighlightBand(stroke: Self.stroke([(50, 50)], height: 24))
        let box = Self.path(band).boundingBox
        #expect(abs(box.minX - 47) < 0.02 && abs(box.minY - 38) < 0.02 && abs(box.width - 6) < 0.02 && abs(box.height - 24) < 0.02)
        #expect(HighlightBand(stroke: Self.stroke([])).polygons.isEmpty)
    }

    /// Round nib (#215): a circle as tall as the band, so ends are half discs and the band is as wide
    /// drawn up as sideways.
    @Test func roundNibHasRoundEndsAndEqualWidthEveryWay() {
        let sideways = Self.path(HighlightBand(stroke: Self.stroke([(100, 100), (300, 100)], nib: .round)))
        #expect(CGRect(x: 89.99, y: 89.99, width: 220.02, height: 20.02).contains(sideways.boundingBox))
        #expect(sideways.boundingBox.width > 219.9 && sideways.boundingBox.height > 19.9)
        #expect(sideways.contains(CGPoint(x: 300, y: 90.5)) && sideways.contains(CGPoint(x: 309.5, y: 100)))
        #expect(!sideways.contains(CGPoint(x: 308, y: 92)), "end is a half disc, not square")
        let upwards = Self.path(HighlightBand(stroke: Self.stroke([(100, 300), (100, 100)], nib: .round)))
        #expect(abs(upwards.boundingBox.width - 20) < 0.02 && abs(upwards.boundingBox.height - 220) < 0.02)
        let dot = Self.path(HighlightBand(stroke: Self.stroke([(50, 50)], height: 24, nib: .round)))
        #expect(abs(dot.boundingBox.width - 24) < 0.02 && abs(dot.boundingBox.height - 24) < 0.02)
        #expect(dot.contains(CGPoint(x: 61.5, y: 50)) && !dot.contains(CGPoint(x: 59, y: 59)), "a disc")
    }

    @Test func nibComesFromTheInk() {
        #expect(HighlightBand(stroke: Self.stroke([(0, 0), (10, 0)])).nib == .chisel, "no rendering: chisel")
        #expect(HighlightBand(stroke: Self.stroke([(0, 0), (10, 0)], nib: .chisel)).nib == .chisel)
        #expect(HighlightBand(stroke: Self.stroke([(0, 0), (10, 0)], nib: .round)).nib == .round)
        #expect(HighlightBand.height(of: Self.stroke([(0, 0), (10, 0)], height: 16, nib: .round)) == 16)
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
