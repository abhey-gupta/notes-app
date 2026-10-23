import Foundation
import InkGeometry
import InkModel

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) {
        state = seed &* 0x2545_F491_4F6C_DD1D &+ 1
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fixtures {
    /// Handwriting-like: smooth heading drift with occasional sharp turns, 240 Hz.
    static func handwriting(_ rng: inout SplitMix64, count: Int? = nil, tool: PenKind? = nil) -> Stroke {
        let n = count ?? Int.random(in: 2 ... 120, using: &rng)
        var p = Point2(Float.random(in: 50 ... 500, using: &rng), Float.random(in: 50 ... 800, using: &rng))
        var heading = Float.random(in: 0 ..< 2 * .pi, using: &rng)
        var force = Float.random(in: 0 ... 1, using: &rng)
        var samples: [Sample] = []
        for i in 0 ..< n {
            samples.append(Sample(
                x: p.x, y: p.y, force: force,
                altitude: Float.random(in: 0.3 ... 1.57, using: &rng),
                azimuth: Float.random(in: 0 ... 6, using: &rng), t: Float(i) / 240
            ))
            heading += Float.random(in: 0 ... 1, using: &rng) < 0.05
                ? Float.random(in: -3 ... 3, using: &rng)
                : Float.random(in: -0.35 ... 0.35, using: &rng)
            let step = Float.random(in: 0.3 ... 4, using: &rng)
            p += step * Point2(cos(heading), sin(heading))
            force = min(max(force + Float.random(in: -0.1 ... 0.1, using: &rng), 0), 1)
        }
        return Stroke(
            tool: tool ?? PenKind.allCases.randomElement(using: &rng) ?? .fountain,
            color: .primary,
            width: Float.random(in: 0.5 ... 16, using: &rng),
            samples: samples
        )
    }

    /// Adversarial: jumps, duplicates, zero/negative dt, out-of-range force.
    static func wild(_ rng: inout SplitMix64) -> Stroke {
        let n = Int.random(in: 1 ... 40, using: &rng)
        var samples: [Sample] = []
        for i in 0 ..< n {
            if let last = samples.last, Bool.random(using: &rng) {
                var s = last
                s.x += Float.random(in: -0.04 ... 0.04, using: &rng)
                samples.append(s)
                continue
            }
            samples.append(Sample(
                x: Float.random(in: 0 ... 60, using: &rng),
                y: Float.random(in: 0 ... 60, using: &rng),
                force: Float.random(in: -1 ... 3, using: &rng),
                altitude: Float.random(in: -1 ... 3, using: &rng),
                t: Float(i % 3) * Float.random(in: -0.01 ... 0.02, using: &rng)
            ))
        }
        return Stroke(
            tool: PenKind.allCases.randomElement(using: &rng) ?? .brush,
            color: .primary,
            width: Float.random(in: 0.01 ... 16, using: &rng),
            samples: samples
        )
    }

    static func line(from a: Point2, to b: Point2, samples n: Int, tool: PenKind = .ballpoint, width: Float = 2) -> Stroke {
        let samples = (0 ..< n).map { i in
            let u = n > 1 ? Float(i) / Float(n - 1) : 0
            let p = a + (b - a) * u
            return Sample(x: p.x, y: p.y, t: Float(i) / 240)
        }
        return Stroke(tool: tool, color: .primary, width: width, samples: samples)
    }
}

/// Twice the signed area of a triangle, in Double.
func doubleArea(_ a: Point2, _ b: Point2, _ c: Point2) -> Double {
    let abx = Double(b.x) - Double(a.x)
    let aby = Double(b.y) - Double(a.y)
    let acx = Double(c.x) - Double(a.x)
    let acy = Double(c.y) - Double(a.y)
    return abx * acy - aby * acx
}

/// Distance from `p` to segment `ab` and the closest parameter.
func segmentDistance(_ p: Point2, _ a: Point2, _ b: Point2) -> (distance: Float, u: Float) {
    let ab = b - a
    let len2 = (ab * ab).sum()
    let u = len2 > 0 ? min(max(((p - a) * ab).sum() / len2, 0), 1) : 0
    let d = p - (a + ab * u)
    return (((d * d).sum()).squareRoot(), u)
}

/// Polyline length.
func polylineLength(_ samples: [Sample]) -> Double {
    zip(samples, samples.dropFirst()).reduce(0) { sum, pair in
        let dx = Double(pair.1.x) - Double(pair.0.x)
        let dy = Double(pair.1.y) - Double(pair.0.y)
        return sum + (dx * dx + dy * dy).squareRoot()
    }
}
