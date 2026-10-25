import CoreGraphics
import Foundation
import InkGeometry
import InkModel
import Testing

/// Length of the polyline outside the disk, by brute-force subdivision.
private func lengthOutside(_ samples: [Sample], center: Point2, radius: Float) -> Double {
    var total = 0.0
    for (a, b) in zip(samples, samples.dropFirst()) {
        let pa = Point2(a.x, a.y)
        let pb = Point2(b.x, b.y)
        let steps = 1000
        for k in 0 ..< steps {
            let u0 = Float(k) / Float(steps)
            let u1 = Float(k + 1) / Float(steps)
            let mid = pa + (pb - pa) * ((u0 + u1) / 2)
            if ((mid - center) * (mid - center)).sum() >= radius * radius {
                let d = (pb - pa) * (u1 - u0)
                total += Double((d * d).sum().squareRoot())
            }
        }
    }
    return total
}

struct EraserSplitTests {
    /// Property: pieces cover exactly the polyline length outside the disk, and lie outside it.
    @Test(arguments: 0 ..< 200)
    func piecesPreserveLengthOutsideDisk(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let stroke = Fixtures.handwriting(&rng, count: Int.random(in: 2 ... 60, using: &rng))
        let s = stroke.samples[Int.random(in: 0 ..< stroke.samples.count, using: &rng)]
        let center = Point2(s.x + Float.random(in: -8 ... 8, using: &rng), s.y + Float.random(in: -8 ... 8, using: &rng))
        let radius = Float.random(in: 0.5 ... 15, using: &rng)
        let expected = lengthOutside(stroke.samples, center: center, radius: radius)
        guard let pieces = EraserSplit.split(stroke.samples, center: center, radius: radius) else {
            #expect(abs(expected - polylineLength(stroke.samples)) < 1e-3)
            return
        }
        let total = pieces.reduce(0) { $0 + polylineLength($1) }
        #expect(abs(total - expected) <= max(1e-3 * expected, 0.02), "seed \(seed)")
        for piece in pieces {
            #expect(piece.count >= 2 && piece[0].t == 0)
            #expect(zip(piece, piece.dropFirst()).allSatisfy { $0.t <= $1.t })
            for p in piece {
                let d = Point2(p.x, p.y) - center
                #expect((d * d).sum().squareRoot() >= radius - 1e-3)
            }
        }
    }

    @Test func cutsAStraightLine() throws {
        let line = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 11).samples
        let pieces = try #require(EraserSplit.split(line, center: Point2(5, 0), radius: 2))
        #expect(pieces.count == 2)
        #expect(pieces[0].first?.x == 0 && pieces[0].last?.x == 3)
        #expect(pieces[1].first?.x == 7 && pieces[1].last?.x == 10)
        #expect(abs((pieces[1].last?.t ?? 0) - 3 / 240) < 1e-6)
        // Whole line inside: fully erased. Far away: untouched.
        #expect(EraserSplit.split(line, center: Point2(5, 0), radius: 20)?.isEmpty == true)
        #expect(EraserSplit.split(line, center: Point2(5, 50), radius: 2) == nil)
        // Tangent touch removes nothing but still counts as untouched.
        #expect(EraserSplit.split(line, center: Point2(5, 2), radius: 2) == nil)
        // Cutting off just the start or the end.
        let head = try #require(EraserSplit.split(line, center: Point2(0, 0), radius: 2.5))
        #expect(head.count == 1 && head[0].first?.x == 2.5)
        let tail = try #require(EraserSplit.split(line, center: Point2(10, 0), radius: 2.5))
        #expect(tail.count == 1 && tail[0].last?.x == 7.5)
        // Tiny remnants are dropped.
        let trimmed = try #require(EraserSplit.split(line, center: Point2(1.5, 0), radius: 1.4, minimumPieceLength: 0.5))
        #expect(trimmed.count == 1)
    }

    @Test func edgeCases() {
        #expect(EraserSplit.split([], center: .zero, radius: 5) == nil)
        #expect(EraserSplit.split([Sample(x: 0, y: 0)], center: .zero, radius: 1) == [])
        #expect(EraserSplit.split([Sample(x: 3, y: 0)], center: .zero, radius: 1) == nil)
        #expect(EraserSplit.split([Sample(x: 0, y: 0), Sample(x: 1, y: 0)], center: .zero, radius: 0) == nil)
        // Zero-length segment inside the disk.
        #expect(EraserSplit.split([Sample(x: 0, y: 0), Sample(x: 0, y: 0)], center: .zero, radius: 1) == [])
    }

    @Test func interpolatesAllFields() throws {
        let a = Sample(x: 0, y: 0, force: 0, altitude: 0, azimuth: 6.2, t: 0)
        let b = Sample(x: 10, y: 0, force: 1, altitude: 1, azimuth: 0.2, t: 1)
        let pieces = try #require(EraserSplit.split([a, b], center: Point2(10, 0), radius: 5))
        let cut = try #require(pieces.first?.last)
        #expect(cut.x == 5 && cut.force == 0.5 && cut.altitude == 0.5 && cut.t == 0.5)
        // Azimuth goes the short way across 2π: 6.2 → 6.2 + ~0.083·... ≈ 6.44.
        #expect(abs(cut.azimuth - (6.2 + (0.2 + 2 * .pi - 6.2) / 2)) < 1e-4)
    }

    @Test func strokePiecesInflateByHalfWidth() throws {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(20, 0), samples: 21, width: 4)
        let pieces = try #require(stroke.pieces(erasedBy: CGPoint(x: 10, y: 0), radius: 2))
        #expect(pieces.count == 2)
        #expect(pieces[0].samples.last?.x == 6 && pieces[1].samples.first?.x == 14)
        #expect(pieces.allSatisfy { $0.id != stroke.id && $0.tool == stroke.tool && $0.width == 4 })
        #expect(stroke.pieces(erasedBy: CGPoint(x: 10, y: 30), radius: 2) == nil)
        // Feeds straight into a replace edit.
        var page = Page(strokes: [stroke])
        try page.apply(page.replaceEdit([stroke.id: pieces]))
        #expect(page.strokes.map(\.id) == pieces.map(\.id))
    }

    /// Property: each piece is the original polyline between its span's ends: original samples
    /// verbatim inside (only `t` rebased), interpolated ends.
    @Test(arguments: 0 ..< 100)
    func piecesKeepOriginalSamples(seed: UInt64) {
        var rng = SplitMix64(seed: seed &+ 1000)
        let samples = Fixtures.handwriting(&rng, count: Int.random(in: 2 ... 80, using: &rng)).samples
        let s = samples[Int.random(in: 0 ..< samples.count, using: &rng)]
        let inflation = samples.map { _ in Float.random(in: 0 ... 6, using: &rng) }
        guard let cuts = EraserSplit.cut(samples, center: Point2(s.x + 2, s.y - 1), radius: 4, inflation: inflation) else { return }
        for cut in cuts {
            let raw = cut.span.values(of: samples, interpolate: EraserSplit.interpolate)
            #expect(raw.count == cut.samples.count)
            let interior = cut.span.start.index + 1 ..< cut.span.end.index + (cut.span.end.fraction > 0 ? 1 : 0)
            let originals = Array(samples[interior])
            let kept = Array(raw.dropFirst().prefix(originals.count))
            #expect(kept == originals, "seed \(seed)")
            let t0 = raw[0].t
            let rebased = raw.map { r in
                var r = r
                r.t -= t0
                return r
            }
            #expect(rebased == cut.samples)
        }
        // Spans are ordered and disjoint.
        for (a, b) in zip(cuts, cuts.dropFirst()) {
            let end = a.span.end
            let start = b.span.start
            #expect(end.index < start.index || (end.index == start.index && end.fraction < start.fraction))
        }
    }

    /// Stored PencilKit point sizes: the disk grows by half of what the ink draws for each point (the
    /// visible width, not the stored size), and the rendering is cut alongside the samples (ink, seed
    /// and group kept; interior points verbatim; ends interpolated).
    @Test func cutsRenderingAlongsideSamples() throws {
        let line = Fixtures.line(from: Point2(0, 0), to: Point2(40, 0), samples: 41, width: 2)
        let points = (0 ... 40).map { i in PointRendering(width: 10, height: 4, opacity: Float(i) / 40) }
        let group = UUID()
        let rendering = StrokeRendering(ink: StrokeRendering.Ink.pen, randomSeed: 7, points: points, renderGroupID: group)
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: line.samples, rendering: rendering)
        let pieces = try #require(stroke.pieces(erasedBy: CGPoint(x: 20, y: 0), radius: 2.5))
        #expect(pieces.count == 2)
        // Pen draws 2 × 10 − 4 = 16 wide: reach 2.5 + 8 = 10.5 (not 2.5 + 10 / 2, nor 2.5 + width / 2).
        #expect(pieces[0].samples.last?.x == 9.5 && pieces[1].samples.first?.x == 30.5)
        for piece in pieces {
            let r = try #require(piece.rendering)
            #expect(r.points.count == piece.samples.count)
            #expect(r.ink == StrokeRendering.Ink.pen && r.randomSeed == 7 && r.renderGroupID == group)
        }
        let first = try #require(pieces[0].rendering)
        #expect(Array(first.points.prefix(10)) == Array(points.prefix(10)))
        #expect(abs((first.points.last?.opacity ?? 0) - 9.5 / 40) < 1e-6)
        #expect(Array(pieces[0].samples.prefix(10)) == Array(line.samples.prefix(10)))
    }

    /// A chisel ink's reach follows the stroke's heading: a fountain-pen line drawn along its azimuth
    /// is the nib's thin side; across it, the thick side.
    @Test func chiselReachFollowsHeading() {
        let points = (0 ... 40).map { _ in PointRendering(width: 10, height: 10) }
        let rendering = StrokeRendering(ink: StrokeRendering.Ink.fountainPen, randomSeed: 1, points: points)
        func cut(azimuth: Float) -> Float? {
            let samples = (0 ... 40).map { i in Sample(x: Float(i), y: 0, azimuth: azimuth, t: Float(i) / 240) }
            let stroke = Stroke(tool: .fountain, color: .primary, width: 2, samples: samples, rendering: rendering)
            return stroke.pieces(erasedBy: CGPoint(x: 20, y: 0), radius: 2)?.first?.samples.last?.x
        }
        #expect(abs((cut(azimuth: 0) ?? 0) - (20 - 2 - 2)) < 1e-3) // across: (10 − 2) / 2 = 4 wide
        #expect(abs((cut(azimuth: .pi / 2) ?? 0) - (20 - 2 - 8)) < 1e-3) // along: 2 × 10 − 4 = 16 wide
    }

    /// Highlighter (butt-capped chisel) strokes split like any other.
    @Test func splitsHighlighter() throws {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(100, 0), samples: 51, tool: .highlighter, width: 16)
        let pieces = try #require(stroke.pieces(erasedBy: CGPoint(x: 50, y: 0), radius: 4))
        #expect(pieces.count == 2 && pieces.allSatisfy { $0.tool == .highlighter && $0.width == 16 })
        #expect(pieces[0].samples.last?.x == 38 && pieces[1].samples.first?.x == 62)
    }
}

struct StrokeIndexTests {
    private func bruteForce(_ entries: [StrokeID: CGRect], _ rect: CGRect) -> Set<StrokeID> {
        Set(entries.filter { b in
            b.value.minX <= rect.maxX && rect.minX <= b.value.maxX && b.value.minY <= rect.maxY && rect.minY <= b.value.maxY
        }.keys)
    }

    /// Property: after random inserts/removes/moves, every query equals a brute-force scan.
    @Test(arguments: 0 ..< 30)
    func matchesBruteForce(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var index = StrokeIndex()
        var truth: [StrokeID: CGRect] = [:]
        for _ in 0 ..< 400 {
            switch Int.random(in: 0 ..< 10, using: &rng) {
            case 0 ..< 6:
                let stroke = Fixtures.handwriting(&rng, count: Int.random(in: 1 ... 30, using: &rng))
                // Some strokes straddle negative coordinates and cell edges.
                let moved = stroke.transformed(by: CGAffineTransform(translationX: .random(in: -300 ... 0, using: &rng), y: 0))
                index.insert(moved)
                truth[moved.id] = moved.bounds
            case 6 ..< 8:
                if let id = truth.keys.randomElement(using: &rng) {
                    let removed = index.remove(id)
                    #expect(removed)
                    truth[id] = nil
                }
            default:
                if let id = truth.keys.randomElement(using: &rng) {
                    let b = CGRect(
                        x: .random(in: -100 ... 600, using: &rng),
                        y: .random(in: -100 ... 900, using: &rng),
                        width: 64,
                        height: 128
                    )
                    index.insert(id, bounds: b)
                    truth[id] = b
                }
            }
            let query = CGRect(
                x: .random(in: -350 ... 600, using: &rng), y: .random(in: -50 ... 850, using: &rng),
                width: .random(in: 0 ... 200, using: &rng), height: .random(in: 0 ... 200, using: &rng)
            )
            let result = index.query(query)
            #expect(result.count == Set(result).count)
            #expect(Set(result) == bruteForce(truth, query))
        }
        #expect(index.count == truth.count)
        #expect(Set(index.query(CGRect(x: -1e5, y: -1e5, width: 2e5, height: 2e5))) == Set(truth.keys))
    }

    @Test func basics() {
        let a = Fixtures.line(from: Point2(10, 10), to: Point2(20, 20), samples: 3)
        let b = Fixtures.line(from: Point2(200, 200), to: Point2(300, 210), samples: 3)
        var index = StrokeIndex(strokes: [a, b], cellSize: 64)
        #expect(index.cellSize == 64 && index.count == 2 && index.contains(a.id) && index.bounds(of: b.id) == b.bounds)
        #expect(index.query(circleCenter: CGPoint(x: 15, y: 15), radius: 2) == [a.id])
        // Touching edges count.
        #expect(index.query(CGRect(x: a.bounds.maxX, y: a.bounds.maxY, width: 0, height: 0)) == [a.id])
        #expect(index.query(.null).isEmpty && index.query(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)).isEmpty)
        let removedStranger = index.remove(StrokeID())
        #expect(!removedStranger)
        index.insert(Stroke(tool: .fountain, color: .primary, width: 2, samples: []))
        #expect(index.count == 2)
        #expect(StrokeIndex(cellSize: -1).cellSize == StrokeIndex.defaultCellSize)
    }

    @Test func hugeStrokesAndQueries() {
        var index = StrokeIndex()
        let small = Fixtures.line(from: Point2(10, 10), to: Point2(20, 20), samples: 3)
        index.insert(small)
        let giant = StrokeID()
        index.insert(giant, bounds: CGRect(x: -1e7, y: -1e7, width: 2e7, height: 2e7))
        #expect(Set(index.query(CGRect(x: 0, y: 0, width: 30, height: 30))) == [small.id, giant])
        #expect(index.query(CGRect(x: 5000, y: 5000, width: 1, height: 1)) == [giant])
        let removedGiant = index.remove(giant)
        #expect(removedGiant)
        #expect(index.query(CGRect(x: 5000, y: 5000, width: 1, height: 1)).isEmpty)
        #expect(index.query(CGRect(x: -1e12, y: -1e12, width: 2e12, height: 2e12)) == [small.id])
    }

    @Test func followsPageEdits() throws {
        var rng = SplitMix64(seed: 5)
        var page = Page(strokes: (0 ..< 6).map { _ in Fixtures.handwriting(&rng, count: 10) })
        var index = StrokeIndex(strokes: page.strokes)
        let ids = page.strokes.map(\.id)
        let edits: [(Page) throws -> PageEdit] = [
            { $0.addEdit([Fixtures.handwriting(&rng, count: 5)]) },
            { try $0.removeEdit([ids[0]]) },
            { try $0.replaceEdit([ids[1]: [Fixtures.handwriting(&rng, count: 4)]]) },
            { try $0.transformEdit([ids[2], ids[3]], by: CGAffineTransform(translationX: 200, y: 50)) },
            { try $0.recolorEdit([ids[4]], to: .semantic(.red)) },
        ]
        for make in edits {
            let edit = try make(page)
            try page.apply(edit)
            index.apply(edit, editedPage: page)
            #expect(index.count == page.strokes.count)
            for stroke in page.strokes {
                #expect(index.bounds(of: stroke.id) == stroke.bounds)
            }
        }
    }
}
