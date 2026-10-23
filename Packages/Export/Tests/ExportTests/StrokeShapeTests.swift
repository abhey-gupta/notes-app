import CoreGraphics
@testable import Export
import InkGeometry
import InkModel
import Testing

struct StrokeShapeTests {
    @Test(arguments: 0 ..< 10)
    func ballpointIsOneStrokedPiece(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        let stroke = Fixtures.handwriting(&rng, tool: .ballpoint)
        let shape = StrokeShape(stroke: stroke, allowsOverlap: true)
        #expect(shape.fills.isEmpty)
        #expect(shape.strokes.count == 1)
        #expect(shape.cap == .round)
        let radii = Centerline(stroke: stroke).radii
        let width = shape.strokes.first?.width ?? 0
        #expect(width == (radii.min() ?? 0) + (radii.max() ?? 0))
    }

    @Test func highlighterIsOneButtCappedPieceEvenWhenTranslucent() {
        var rng = SplitMix64(state: 7)
        let shape = StrokeShape(stroke: Fixtures.handwriting(&rng, tool: .highlighter), allowsOverlap: false)
        #expect(shape.fills.isEmpty)
        #expect(shape.strokes.count == 1)
        #expect(shape.cap == .butt)
    }

    /// Every centerline point is within the edge tolerance of some piece's half width, and pieces chain
    /// end to start.
    @Test(arguments: 0 ..< 10)
    func fountainPiecesFollowTheWidth(seed: UInt64) {
        var rng = SplitMix64(state: seed)
        let stroke = Fixtures.handwriting(&rng, tool: .fountain)
        let shape = StrokeShape(stroke: stroke, allowsOverlap: true)
        let pieces = shape.strokes
        #expect(shape.fills.isEmpty)
        for (a, b) in zip(pieces, pieces.dropFirst()) {
            #expect(a.path.segments.last?.end == b.path.start)
        }
        let radii = Centerline(stroke: stroke).radii
        for r in radii {
            #expect(pieces.contains { abs($0.width / 2 - r) <= StrokeShape.edgeTolerance(width: $0.width) + 1e-4 })
        }
    }

    @Test func pressureTaperNeedsSeveralPieces() {
        let samples = (0 ..< 60).map { i in
            Sample(x: Float(i), y: 100, force: Float(i) / 59, t: Float(i) / 240)
        }
        let stroke = Stroke(tool: .fountain, color: .primary, width: 3, samples: samples)
        let shape = StrokeShape(stroke: stroke, allowsOverlap: true)
        #expect(shape.strokes.count > 3)
        // Translucent ink can't overlap pieces: outline instead.
        let translucent = StrokeShape(stroke: stroke, allowsOverlap: false)
        #expect(translucent.strokes.isEmpty)
        #expect(!translucent.fills.isEmpty)
    }

    @Test func dotIsAFilledCircle() {
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 3, samples: [Sample(x: 10, y: 10, t: 0)])
        let shape = StrokeShape(stroke: stroke, allowsOverlap: true)
        #expect(shape.strokes.isEmpty)
        #expect(shape.fills.count == 1)
    }
}
