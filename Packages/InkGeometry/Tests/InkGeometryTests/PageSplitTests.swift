import CoreGraphics
import InkGeometry
import InkModel
import Testing

/// Strokes running from one page onto the next (#163).
struct PageSplitTests {
    /// Three 100 × 200 pages stacked without gaps, and a 600-wide content space (gutters either side).
    let pages: [(id: PageID, frame: CGRect)] = (0 ..< 3).map { i in
        (PageID(), CGRect(x: 250, y: CGFloat(i) * 200, width: 100, height: 200))
    }

    @Test func strokeOnOnePageIsKeptWhole() {
        let stroke = Fixtures.line(from: Point2(10, 10), to: Point2(90, 190), samples: 20)
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        #expect(pieces.count == 1)
        #expect(pieces[0].page == pages[0].id)
        #expect(pieces[0].stroke == stroke)
    }

    @Test func strokeDownAcrossTheSeamIsCutAtTheEdge() throws {
        // (50, 150) on page 0 down to (50, 250): 50 pt on page 0, 50 pt on page 1.
        let stroke = Fixtures.line(from: Point2(50, 150), to: Point2(50, 250), samples: 11)
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        try #require(pieces.count == 2)
        #expect(pieces.map(\.page) == [pages[0].id, pages[1].id])
        #expect(pieces[0].stroke.id == stroke.id)
        #expect(pieces[1].stroke.id != stroke.id)
        let first = pieces[0].stroke.samples
        let second = pieces[1].stroke.samples
        #expect(first.first?.y == 150)
        #expect(first.last?.y == 200)
        // Page 1's piece is in page 1's space: it starts at its top edge.
        #expect(second.first?.y == 0)
        #expect(second.last?.y == 50)
        #expect(second.allSatisfy { $0.x == 50 })
        #expect(second.first?.t == 0)
        #expect(pieces.allSatisfy { $0.stroke.tool == stroke.tool && $0.stroke.width == stroke.width })
    }

    @Test func cutBetweenSamplesInterpolates() throws {
        // One segment straddles the seam: (50, 190) → (60, 210), force 0.2 → 0.6, t 0 → 0.1.
        let samples = [
            Sample(x: 50, y: 190, force: 0.2, t: 0),
            Sample(x: 60, y: 210, force: 0.6, t: 0.1),
        ]
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: samples)
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        try #require(pieces.count == 2)
        let end = try #require(pieces[0].stroke.samples.last)
        let start = try #require(pieces[1].stroke.samples.first)
        #expect(abs(end.x - 55) < 1e-4 && abs(end.y - 200) < 1e-4)
        #expect(abs(end.force - 0.4) < 1e-4)
        #expect(abs(start.x - 55) < 1e-4 && abs(start.y) < 1e-4)
        #expect(start.t == 0)
        #expect(abs((pieces[1].stroke.samples.last?.t ?? 0) - 0.05) < 1e-4)
    }

    @Test func renderingIsCutAlongside() throws {
        let samples = [Sample(x: 50, y: 190, t: 0), Sample(x: 50, y: 210, t: 0.1)]
        let rendering = StrokeRendering(
            ink: StrokeRendering.Ink.pen, randomSeed: 7,
            points: [PointRendering(width: 2, height: 2), PointRendering(width: 4, height: 4)]
        )
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: samples, rendering: rendering)
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        try #require(pieces.count == 2)
        for piece in pieces {
            let pieceRendering = try #require(piece.stroke.rendering)
            #expect(pieceRendering.points.count == piece.stroke.samples.count)
            #expect(pieceRendering.randomSeed == 7)
        }
        #expect(pieces[0].stroke.rendering?.points.last?.width == 3)
        #expect(pieces[1].stroke.rendering?.points.first?.width == 3)
    }

    @Test func strokeUpOntoThePageAbove() throws {
        let stroke = Fixtures.line(from: Point2(50, 20), to: Point2(50, -30), samples: 6)
        let pieces = stroke.pieces(from: pages[1].id, across: pages)
        try #require(pieces.count == 2)
        #expect(pieces.map(\.page) == [pages[1].id, pages[0].id])
        #expect(pieces[0].stroke.samples.last?.y == 0)
        #expect(pieces[1].stroke.samples.first?.y == 200)
        #expect(pieces[1].stroke.samples.last?.y == 170)
    }

    @Test func strokeAcrossThreePagesAndBack() {
        // Page 0 → page 1 → page 2 → back up into page 1.
        let points: [Point2] = [Point2(50, 180), Point2(50, 220), Point2(50, 380), Point2(50, 420), Point2(50, 390)]
        let stroke = Stroke(
            tool: .fountain, color: .primary, width: 2,
            samples: points.enumerated().map { Sample(x: $1.x, y: $1.y, t: Float($0) / 240) }
        )
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        #expect(pieces.map(\.page) == [pages[0].id, pages[1].id, pages[2].id, pages[1].id])
        #expect(Set(pieces.map(\.stroke.id)).count == 4)
        #expect(pieces[3].stroke.samples.map(\.y) == [200, 190])
    }

    @Test func gutterStaysWithTheLastPage() throws {
        // Off page 0 to the right (gutter), down past the seam, then left onto page 1.
        let points: [Point2] = [Point2(80, 150), Point2(150, 150), Point2(150, 250), Point2(80, 250)]
        let stroke = Stroke(
            tool: .ballpoint, color: .primary, width: 2,
            samples: points.enumerated().map { Sample(x: $1.x, y: $1.y, t: Float($0)) }
        )
        let pieces = stroke.pieces(from: pages[0].id, across: pages)
        try #require(pieces.count == 2)
        #expect(pieces[0].stroke.samples.map(\.x) == [80, 150, 150, 100])
        #expect(pieces[1].stroke.samples.map(\.x) == [100, 80])
        #expect(pieces[1].stroke.samples.map(\.y) == [50, 50])
    }

    @Test func strokeLeavingEveryPageIsKeptWhole() {
        let stroke = Fixtures.line(from: Point2(50, 50), to: Point2(200, 50), samples: 8)
        #expect(stroke.pieces(from: pages[0].id, across: pages).map(\.stroke) == [stroke])
    }

    @Test func unknownPageKeepsTheStroke() {
        let stroke = Fixtures.line(from: Point2(50, 150), to: Point2(50, 250), samples: 8)
        let elsewhere = PageID()
        #expect(stroke.pieces(from: elsewhere, across: pages).map(\.page) == [elsewhere])
    }

    /// Property: the pieces, mapped back to the first page's space, retrace the stroke (same length) and each
    /// lies on its page.
    @Test(arguments: 0 ..< 200)
    func piecesRetraceTheStroke(seed: UInt64) throws {
        var rng = SplitMix64(seed: seed)
        var stroke = Fixtures.handwriting(&rng, count: Int.random(in: 2 ... 120, using: &rng))
        // Start near the seam so many strokes cross it.
        stroke = stroke.transformed(by: CGAffineTransform(
            translationX: 50 - (stroke.samples.first.map { CGFloat($0.x) } ?? 0),
            y: 190 - (stroke.samples.first.map { CGFloat($0.y) } ?? 0)
        ))
        let start = pages[1]
        let pieces = stroke.pieces(from: start.id, across: pages)
        let total = pieces.reduce(0) { $0 + polylineLength($1.stroke.samples) }
        #expect(abs(total - polylineLength(stroke.samples)) < 1e-2)
        for piece in pieces.dropFirst() {
            let frame = try #require(pages.first { $0.id == piece.page }?.frame)
            let first = piece.stroke.samples[0]
            let edge = CGRect(origin: .zero, size: frame.size).insetBy(dx: -0.01, dy: -0.01)
            #expect(edge.contains(CGPoint(x: CGFloat(first.x), y: CGFloat(first.y))))
        }
    }
}
