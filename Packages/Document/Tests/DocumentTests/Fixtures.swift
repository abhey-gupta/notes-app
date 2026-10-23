@testable import Document
import Foundation
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
    static func stroke(_ rng: inout SplitMix64, samples: Int? = nil) -> Stroke {
        let n = samples ?? Int.random(in: 0 ... 150, using: &rng)
        var x = Float.random(in: 0 ... 595, using: &rng)
        var y = Float.random(in: 0 ... 842, using: &rng)
        let samples = (0 ..< n).map { i in
            x += Float.random(in: -3 ... 3, using: &rng)
            y += Float.random(in: -3 ... 3, using: &rng)
            return Sample(
                x: x, y: y,
                force: Float.random(in: 0 ... 1, using: &rng),
                altitude: Float.random(in: 0.3 ... 1.57, using: &rng),
                azimuth: Float.random(in: 0 ... 6.28, using: &rng),
                t: Float(i) / 240
            )
        }
        let color: InkColor = Bool.random(using: &rng)
            ? .semantic(SemanticInk.allCases.randomElement(using: &rng) ?? .primary)
            : .custom(RGBA8(rgba: UInt32.random(in: 0 ... .max, using: &rng)))
        let id = StrokeID(uuid: UUIDv7.make(
            milliseconds: rng.next() >> 16,
            randA: UInt16.random(in: 0 ... .max, using: &rng),
            randB: rng.next()
        ))
        return Stroke(
            id: id,
            tool: PenKind.allCases.randomElement(using: &rng) ?? .fountain,
            color: color,
            width: Float.random(in: 0.5 ... 16, using: &rng),
            samples: samples
        )
    }

    static func strokes(_ rng: inout SplitMix64, count: Int, samples: Int? = nil) -> [Stroke] {
        (0 ..< count).map { _ in stroke(&rng, samples: samples) }
    }

    /// Realistic dense page: 400 strokes × 60 samples (§12).
    static func densePage(seed: UInt64 = 400) -> [Stroke] {
        var rng = SplitMix64(seed: seed)
        return strokes(&rng, count: 400, samples: 60)
    }
}

/// Fresh temp directory, removed when the closure returns.
func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
    let dir = FileManager.default.temporaryDirectory.appending(path: "DocumentTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

/// Median and best of `rounds` timings of `body`, in milliseconds.
func measureMilliseconds(rounds: Int, _ body: () throws -> Void) rethrows -> (median: Double, best: Double) {
    let clock = ContinuousClock()
    var times: [Double] = []
    for _ in 0 ..< rounds {
        let elapsed = try clock.measure(body)
        times.append(Double(elapsed.components.seconds) * 1e3 + Double(elapsed.components.attoseconds) / 1e15)
    }
    times.sort()
    return (times[times.count / 2], times[0])
}

let isReleaseBuild: Bool = {
    #if DEBUG
        false
    #else
        true
    #endif
}()

func report(_ line: String) {
    FileHandle.standardError.write(Data("\(line) (\(isReleaseBuild ? "release" : "debug"))\n".utf8))
}
