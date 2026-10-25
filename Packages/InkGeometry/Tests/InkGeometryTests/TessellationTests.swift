import CoreGraphics
import InkGeometry
import InkModel
import Testing

private func contains(_ outer: CGRect, _ inner: CGRect, slack: CGFloat = 1e-3) -> Bool {
    inner.isNull || outer.insetBy(dx: -slack, dy: -slack).contains(inner)
}

struct CenterlineTests {
    @Test func resamplesAtAboutOnePoint() {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(100, 0), samples: 11)
        let c = Centerline(stroke: stroke)
        #expect(c.points.count == 101)
        #expect(c.points.first == Point2(0, 0) && c.points.last == Point2(100, 0))
        #expect(abs(c.length - 100) < 1e-3)
        for (a, b) in zip(c.points, c.points.dropFirst()) {
            #expect(abs(b.x - a.x - 1) < 1e-3 && b.y == 0)
        }
        #expect(c.arcLengths.count == c.points.count && c.radii.count == c.points.count)
        let wide = Centerline(stroke: stroke, spacing: 5)
        #expect(wide.points.count == 21)
    }

    @Test(arguments: 0 ..< 200)
    func staysInsideStrokeBoundsAndSpacing(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let stroke = seed.isMultiple(of: 2) ? Fixtures.handwriting(&rng) : Fixtures.wild(&rng)
        let c = Centerline(stroke: stroke)
        #expect(contains(stroke.bounds, c.bounds))
        let maxRadius = stroke.width * Stroke.maxWidthScale / 2
        for r in c.radii {
            #expect(r.isFinite && r > 0 && r <= max(maxRadius, Centerline.minimumWidth) + 1e-4)
        }
        for (a, b) in zip(c.points, c.points.dropFirst()) {
            let d = ((b - a) * (b - a)).sum().squareRoot()
            #expect(d > 1e-3)
        }
    }

    @Test func storedRenderingSetsRadii() {
        let line = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 3)
        let rendering = StrokeRendering(ink: StrokeRendering.Ink.pen, randomSeed: 1, points: [
            PointRendering(width: 2, height: 2), PointRendering(width: 6, height: 4), PointRendering(width: 10, height: 10),
        ])
        let stroke = Stroke(tool: line.tool, color: line.color, width: line.width, samples: line.samples, rendering: rendering)
        let c = Centerline(stroke: stroke)
        #expect(c.radii.first == 1 && c.radii.last == 5)
        #expect(c.radii[c.points.count / 2] == 3) // midpoint sample: max(6, 4) / 2
        #expect(contains(stroke.bounds, c.bounds))
    }

    @Test func derivedRenderingFollowsProfileAndIsStable() {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 3)
        let derived = stroke.derivedRendering
        #expect(derived.ink == StrokeRendering.Ink.for(stroke.tool))
        #expect(derived.points.count == 3)
        let scale = PenProfile(stroke.tool).widthScale(force: stroke.samples[0].force, speed: 0, altitude: stroke.samples[0].altitude)
        #expect(derived.points[0] == PointRendering(width: stroke.width * scale, height: stroke.width * scale))
        #expect(stroke.derivedRendering == derived)
        #expect(stroke.resolvedRendering == derived)
    }

    @Test func dropsNonFiniteAndDuplicateSamples() {
        let samples = [
            Sample(x: 1, y: 1), Sample(x: .nan, y: 3), Sample(x: 1.01, y: 1), Sample(x: .infinity, y: 0), Sample(x: 3, y: 1, t: 0.01),
        ]
        let c = Centerline(samples: samples, width: 2, profile: .ballpoint)
        #expect(c.points.first == Point2(1, 1) && c.points.last == Point2(3, 1))
        #expect(c.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(Centerline(samples: [], width: 2, profile: .fountain).points.isEmpty)
        #expect(Centerline(samples: [], width: 2, profile: .fountain).bounds.isNull)
        #expect(Centerline(samples: [Sample(x: .nan, y: 0)], width: 2, profile: .fountain).length == 0)
    }

    @Test func dots() {
        let dot = Centerline(samples: [Sample(x: 5, y: 5)], width: 4, profile: .ballpoint)
        #expect(dot.points == [Point2(5, 5)])
        let r = dot.radii[0]
        #expect(dot.bounds == CGRect(x: CGFloat(5 - r), y: CGFloat(5 - r), width: CGFloat(2 * r), height: CGFloat(2 * r)))
        let chisel = Centerline(samples: [Sample(x: 5, y: 5)], width: 4, profile: .highlighter)
        #expect(chisel.points == [Point2(4, 5), Point2(6, 5)])
        #expect(chisel.capStyle == .butt)
    }
}

struct PenProfileTests {
    @Test func scalesStayInRange() {
        for kind in PenKind.allCases {
            let profile = PenProfile(kind)
            for force: Float in [-1, 0, 0.25, 0.5, 1, 4, .nan] {
                for speed: Float in [0, 100, 1000, 1e6, .infinity, .nan] {
                    for altitude: Float in [0, 0.5, .pi / 2, 3, .nan] {
                        let s = profile.widthScale(force: force, speed: speed, altitude: altitude)
                        #expect(s >= PenProfile.minWidthScale && s <= Stroke.maxWidthScale)
                    }
                }
            }
        }
    }

    @Test func characterOfEachPen() {
        let f = PenProfile.fountain
        #expect(f.widthScale(force: 1, speed: 0, altitude: 1.5) > f.widthScale(force: 0.2, speed: 0, altitude: 1.5))
        #expect(f.widthScale(force: 0.5, speed: 2000, altitude: 1.5) < f.widthScale(force: 0.5, speed: 0, altitude: 1.5))
        let b = PenProfile.ballpoint
        let spread = b.widthScale(force: 1, speed: 0, altitude: 0) - b.widthScale(force: 0, speed: 3000, altitude: 1.5)
        #expect(spread <= 0.2 + 1e-6)
        let brush = PenProfile.brush
        #expect(brush.widthScale(force: 0.5, speed: 0, altitude: 0.2) > brush.widthScale(force: 0.5, speed: 0, altitude: 1.5))
        #expect(brush.edgeSoftness > 0 && brush.capStyle == .round)
        let h = PenProfile.highlighter
        #expect(h.widthScale(force: 0, speed: 0, altitude: 0) == 1 && h.widthScale(force: 1, speed: 9000, altitude: 1.5) == 1)
        #expect(h.capStyle == .butt && h.drawsBeneathInk && h.opacity == 0.4)
        #expect(!f.drawsBeneathInk && f.opacity == 1 && f.edgeSoftness == 0)
    }
}

struct TessellationTests {
    @Test func vertexLayoutIsGPUReady() {
        #expect(MemoryLayout<StrokeVertex>.size == 24)
        #expect(MemoryLayout<StrokeVertex>.stride == 24)
        #expect(MemoryLayout<StrokeVertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<StrokeVertex>.offset(of: \.edge) == 8)
        #expect(MemoryLayout<StrokeVertex>.offset(of: \.radius) == 16)
        #expect(MemoryLayout<StrokeVertex>.offset(of: \.arcLength) == 20)
    }

    /// Property: never NaN, never a degenerate (zero-area) triangle, always inside `stroke.bounds`.
    @Test(arguments: 0 ..< 1000)
    func noNaNOrDegenerateTriangles(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        let stroke = seed % 4 == 3 ? Fixtures.wild(&rng) : Fixtures.handwriting(&rng)
        let fringe = Float.random(in: 0.25 ... 2, using: &rng)
        let centerline = Centerline(stroke: stroke)
        let mesh = StrokeTessellator.mesh(for: centerline, fringe: fringe)
        let extra = mesh.vertices.count - 2 * (centerline.points.count + 2)
        #expect(extra >= 0 && extra.isMultiple(of: 6))
        #expect(mesh.triangleCount == mesh.vertices.count - 2)
        for v in mesh.vertices {
            #expect(v.position.x.isFinite && v.position.y.isFinite && v.edge.x.isFinite && v.edge.y.isFinite)
            #expect(v.radius.isFinite && v.radius > 0 && v.arcLength.isFinite)
        }
        let v = mesh.vertices
        var degenerate = 0
        for i in 0 ..< mesh.triangleCount where abs(doubleArea(v[i].position, v[i + 1].position, v[i + 2].position)) < 1e-6 {
            degenerate += 1
        }
        #expect(degenerate == 0, "seed \(seed)")
        #expect(contains(stroke.bounds, mesh.bounds))
    }

    @Test func straightLineAttributes() throws {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 2, width: 4)
        let mesh = StrokeTessellator.mesh(for: stroke, fringe: 1)
        let r = try #require(mesh.vertices.first).radius
        #expect(mesh.capStyle == .round)
        // Start cap pair sits radius + fringe behind the first point.
        #expect(mesh.vertices[0].position == Point2(-(r + 1), r + 1))
        #expect(mesh.vertices[1].position == Point2(-(r + 1), -(r + 1)))
        #expect(mesh.vertices[0].edge == Point2(r + 1, r + 1) && mesh.vertices[1].edge == Point2(r + 1, -(r + 1)))
        // Body pairs: along = 0.
        #expect(mesh.vertices[2].edge == Point2(0, r + 1))
        let last = mesh.vertices[mesh.vertices.count - 1]
        #expect(last.position.x == 10 + r + 1 && last.arcLength == 10)
        #expect(mesh.bounds == CGRect(
            x: CGFloat(-(r + 1)),
            y: CGFloat(-(r + 1)),
            width: CGFloat(10 + 2 * (r + 1)),
            height: CGFloat(2 * (r + 1))
        ))
    }

    @Test func sharpTurnsBreakTheStripWithCaps() {
        let hairpin = Stroke(tool: .ballpoint, color: .primary, width: 4, samples: [
            Sample(x: 0, y: 0, t: 0), Sample(x: 10, y: 0, t: 0.02), Sample(x: 0, y: 1, t: 0.04),
        ])
        let c = Centerline(stroke: hairpin)
        let mesh = StrokeTessellator.mesh(for: c)
        let extra = mesh.vertices.count - 2 * (c.points.count + 2)
        #expect(extra > 0 && extra.isMultiple(of: 6))
        // Break caps sit at along = radius + fringe, so bridging triangles have zero coverage.
        let caps = mesh.vertices.dropFirst(2).dropLast(2).filter { $0.edge.x > 0 }
        #expect(!caps.isEmpty && caps.allSatisfy { abs($0.edge.x - abs($0.edge.y)) < 1e-5 })
        // Highlighters never break (flat caps would notch the corner).
        let flat = Stroke(tool: .highlighter, color: .primary, width: 4, samples: hairpin.samples)
        let fc = Centerline(stroke: flat)
        #expect(StrokeTessellator.mesh(for: fc).vertices.count == 2 * (fc.points.count + 2))
    }

    @Test func buttCapsExtendOnlyByFringe() {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 3, tool: .highlighter, width: 6)
        let mesh = StrokeTessellator.mesh(for: stroke, fringe: 0.5)
        #expect(mesh.capStyle == .butt)
        #expect(mesh.vertices[0].position.x == -0.5 && mesh.vertices[0].edge.x == 0.5)
        #expect(mesh.vertices[0].edge.y == 3.5)
    }

    @Test func fringeIsClampedAndEmptyStrokeHasNoGeometry() {
        let stroke = Fixtures.line(from: Point2(0, 0), to: Point2(10, 0), samples: 2)
        let huge = StrokeTessellator.mesh(for: stroke, fringe: 100)
        #expect(contains(stroke.bounds, huge.bounds))
        let nan = StrokeTessellator.mesh(for: stroke, fringe: .nan)
        let finite = nan.vertices.allSatisfy(\.position.x.isFinite)
        #expect(finite)
        let empty = StrokeTessellator.mesh(for: Stroke(tool: .fountain, color: .primary, width: 2, samples: []))
        #expect(empty.vertices.isEmpty && empty.bounds.isNull && empty.triangleCount == 0)
    }

    @Test func appendingReusesOneBuffer() {
        var rng = SplitMix64(seed: 42)
        var buffer: [StrokeVertex] = []
        var total = 0
        for _ in 0 ..< 5 {
            let c = Centerline(stroke: Fixtures.handwriting(&rng))
            StrokeTessellator.appendVertices(for: c, fringe: 1, to: &buffer)
            total += StrokeTessellator.mesh(for: c).vertices.count
        }
        #expect(buffer.count == total)
    }
}

/// The fragment coverage formulas documented on ``StrokeVertex`` (#65), evaluated on the CPU.
struct CoverageFormulaTests {
    private static let ppp: Float = 2

    private static func coverage(edge: Point2, radius: Float, butt: Bool) -> Float {
        let along = max(edge.x, 0)
        let d: Float = if !butt {
            (along * along + edge.y * edge.y).squareRoot()
        } else if edge.x > 0 {
            max(abs(edge.y), radius + edge.x)
        } else {
            abs(edge.y)
        }
        return min(max((radius - d) * ppp + 0.5, 0), 1)
    }

    @Test(arguments: [false, true])
    func bodyIsSolidAndEdgesAntialias(butt: Bool) {
        let r: Float = 3
        #expect(Self.coverage(edge: Point2(x: 0, y: 0), radius: r, butt: butt) == 1)
        #expect(Self.coverage(edge: Point2(x: 0, y: 2), radius: r, butt: butt) == 1)
        #expect(Self.coverage(edge: Point2(x: 0, y: r), radius: r, butt: butt) == 0.5)
        #expect(Self.coverage(edge: Point2(x: 0, y: r + 1), radius: r, butt: butt) == 0)
    }

    @Test func buttCapsEndAtTheEndPlaneRoundCapsReachRadius() {
        let r: Float = 3
        // Just past the end: round caps still solid, butt caps half-covered at the plane, gone beyond it.
        #expect(Self.coverage(edge: Point2(x: 1, y: 0), radius: r, butt: false) == 1)
        #expect(Self.coverage(edge: Point2(x: 0.0001, y: 0), radius: r, butt: true) > 0.49)
        #expect(Self.coverage(edge: Point2(x: 1, y: 0), radius: r, butt: true) == 0)
        #expect(Self.coverage(edge: Point2(x: r, y: 0), radius: r, butt: false) == 0.5)
    }
}
