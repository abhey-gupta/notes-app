import Foundation
import InkGeometry
import InkModel
import Testing

private let isReleaseBuild: Bool = {
    #if DEBUG
        false
    #else
        true
    #endif
}()

/// Budget: tessellating a 60-sample stroke (smooth + resample + profile + strip) < 50 µs in release.
/// Run with `swift test -c release --filter PerformanceTests`; prints the median to stderr.
struct PerformanceTests {
    @Test func tessellate60SampleStroke() {
        var rng = SplitMix64(seed: 60)
        // ~1.2 pt per sample at 240 Hz ≈ 290 pt/s handwriting, fountain pen (velocity + pressure).
        let stroke = Fixtures.handwriting(&rng, count: 60, tool: .fountain)
        let clock = ContinuousClock()
        var buffer: [StrokeVertex] = []
        var sink = 0
        var perStroke: [Double] = []
        let iterations = isReleaseBuild ? 500 : 10
        for _ in 0 ..< 30 {
            let elapsed = clock.measure {
                for _ in 0 ..< iterations {
                    buffer.removeAll(keepingCapacity: true)
                    StrokeTessellator.appendVertices(for: Centerline(stroke: stroke), fringe: 1, to: &buffer)
                    sink &+= buffer.count
                }
            }
            perStroke
                .append(Double(elapsed.components.attoseconds) / 1e12 / Double(iterations) + Double(elapsed.components.seconds) * 1e6 /
                    Double(iterations))
        }
        perStroke.sort()
        let median = perStroke[perStroke.count / 2]
        let line = String(
            format: "tessellate 60 samples → %d vertices: median %.2f µs, best %.2f µs (%@)\n",
            buffer.count,
            median,
            perStroke[0],
            isReleaseBuild ? "release" : "debug"
        )
        FileHandle.standardError.write(Data(line.utf8))
        #expect(sink > 0)
        if isReleaseBuild {
            #expect(median < 50, "median \(median) µs")
        }
    }
}
