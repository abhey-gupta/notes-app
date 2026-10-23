import CoreGraphics
import InkGeometry
import InkModel
import Testing
import Tools

struct StrokeEraserTests {
    /// Horizontal ballpoint line from `x0` to `x1` at `y`.
    private func line(_ x0: Float, _ x1: Float, y: Float, width: Float = 2) -> Stroke {
        Stroke(
            tool: .ballpoint, color: .primary, width: width,
            samples: stride(from: x0, through: x1, by: 2).map { Sample(x: $0, y: y, t: 0) }
        )
    }

    private func point(_ x: Float, _ y: Float) -> Sample {
        Sample(x: x, y: y, t: 0)
    }

    @Test func hitsOnlyTouchedStrokesOnce() {
        let a = line(100, 300, y: 100)
        let b = line(100, 300, y: 200)
        var eraser = StrokeEraser(page: Page(strokes: [a, b]), diameter: 16)
        #expect(eraser.erase([point(150, 150)]).isEmpty, "50 pt from both lines")
        #expect(eraser.erase([point(150, 106)]) == [a.id])
        #expect(eraser.erase([point(160, 100)]).isEmpty, "already erased")
        #expect(eraser.remainingCount == 1)
    }

    /// A fast flick between two batches still hits a thin stroke it crossed.
    @Test func sweepsBetweenSamplesAcrossBatches() {
        let vertical = Stroke(
            tool: .fountain, color: .primary, width: 1,
            samples: stride(from: Float(0), through: 400, by: 4).map { Sample(x: 300, y: $0, t: 0) }
        )
        var eraser = StrokeEraser(page: Page(strokes: [vertical]), diameter: 8)
        #expect(eraser.erase([point(50, 200)]).isEmpty)
        #expect(eraser.erase([point(550, 200)]) == [vertical.id], "the path from 50 to 550 crosses x = 300")
    }

    @Test func emptyPageAndNonFiniteInput() {
        var eraser = StrokeEraser(page: Page(), diameter: 16)
        #expect(eraser.erase([point(10, 10), Sample(x: .nan, y: 3, t: 0)]).isEmpty)
        var dense = StrokeEraser(page: Page(strokes: [line(0, 100, y: 0)]), diameter: 16)
        #expect(dense.erase([Sample(x: .infinity, y: 0, t: 0)]).isEmpty)
    }

    /// Matches a brute-force disk test along the same swept path on random pages.
    @Test(arguments: 0 ..< 8)
    func matchesBruteForce(seed: UInt64) {
        var rng = SplitMix64(state: seed &+ 77)
        let page = Page(strokes: (0 ..< 30).map { _ in randomStroke(&rng) })
        var eraser = StrokeEraser(page: page, diameter: 16)
        var path: [CGPoint] = []
        var hits = Set<StrokeID>()
        for _ in 0 ..< 3 {
            let batch = (0 ..< 3).map { _ in CGPoint(x: .random(in: 0 ... 595, using: &rng), y: .random(in: 0 ... 842, using: &rng)) }
            hits.formUnion(eraser.erase(batch))
            path += batch
        }
        var probes: [CGPoint] = [path[0]]
        for (a, b) in zip(path, path.dropFirst()) {
            let n = max(Int((hypot(b.x - a.x, b.y - a.y) / 4).rounded(.up)), 1)
            probes += (1 ... n).map { i in
                let t = CGFloat(i) / CGFloat(n)
                return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
        }
        let expected = Set(page.strokes.filter { s in probes.contains { s.intersects(circleCenter: $0, radius: 8) } }.map(\.id))
        #expect(hits == expected)
        #expect(eraser.remainingCount == page.strokes.count - hits.count)
    }
}
