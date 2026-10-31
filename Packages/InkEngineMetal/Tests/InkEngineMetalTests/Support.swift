import CoreGraphics
import Foundation
import ImageIO
import InkEngine
@testable import InkEngineMetal
import InkEngineTestSupport
import InkModel
import Testing
import UniformTypeIdentifiers

@MainActor
final class Recorder: InkEngineDelegate {
    var commits: [(Stroke, PageID)] = []
    var eraser: [([Sample], PageID)] = []
    var lassos: [([CGPoint], PageID)] = []
    var begins = 0
    var sharp: [PageID] = []
    /// Echo commits back like the document does.
    var echo: ((Stroke, PageID) -> Void)?

    func engine(_: any InkEngine, didCommit pieces: [(page: PageID, stroke: Stroke)]) {
        for (page, stroke) in pieces {
            commits.append((stroke, page))
            echo?(stroke, page)
        }
    }

    func engine(_: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID) {
        eraser.append((samples, page))
    }

    func engine(_: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID) {
        lassos.append((path, page))
    }

    func engineDidBeginStroke(_: any InkEngine) {
        begins += 1
    }

    func engineDidHoldToErase(_: any InkEngine) {}

    func engine(_: any InkEngine, didShowSharpInkOn page: PageID) {
        sharp.append(page)
    }
}

extension PageSnapshot {
    func appending(_ strokes: [Stroke]) -> PageSnapshot {
        // swiftlint:disable:next force_try
        try! applying(page.addEdit(strokes))
    }
}

/// 8-bit sRGB RGBA pixels of a `CGImage`.
struct RGBAPixels: Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }

    /// Pixel at `(x, y)`, origin top-left.
    subscript(x: Int, y: Int) -> RGBA8 {
        let i = (y * width + x) * 4
        return RGBA8(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
    }

    /// Largest channel difference from `color` at `(x, y)`.
    func delta(_ x: Int, _ y: Int, from color: RGBA8) -> Int {
        let p = self[x, y]
        return max(abs(Int(p.r) - Int(color.r)), abs(Int(p.g) - Int(color.g)), abs(Int(p.b) - Int(color.b)))
    }

    /// Pixels that differ from `paper` by more than `threshold` (ink, template marks).
    func mask(differingFrom paper: RGBA8, threshold: Int = 48) -> [Bool] {
        (0 ..< width * height).map { delta($0 % width, $0 / width, from: paper) > threshold }
    }
}

/// Perceptual comparison against golden PNGs.
///
/// Tolerance: GPU/driver differences move AA edge pixels by a few levels, so a pixel only counts as
/// different above 40/255 on any channel; the test fails if more than 0.3 % of pixels differ or the
/// mean channel difference exceeds 1.5/255. A misplaced, missing or re-styled stroke blows through both.
///
/// Recording: a missing golden (or `INK_RECORD_GOLDENS=1` in the test environment; with xcodebuild,
/// `TEST_RUNNER_INK_RECORD_GOLDENS=1`) writes the render into `Goldens/` in the source tree and
/// fails the test so the new image gets reviewed. Failed comparisons write the actual image to
/// `/tmp/InkEngineMetalSnapshots/`.
enum Golden {
    static let pixelThreshold = 40
    static let maxDifferingFraction = 0.003
    static let maxMeanDelta = 1.5

    static var sourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens")
    }

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["INK_RECORD_GOLDENS"] == "1"
    }

    struct Difference {
        var differingFraction: Double
        var meanDelta: Double
    }

    static func difference(_ a: RGBAPixels, _ b: RGBAPixels) -> Difference? {
        guard a.width == b.width, a.height == b.height else { return nil }
        var differing = 0
        var total = 0
        for p in 0 ..< a.width * a.height {
            var worst = 0
            for c in 0 ..< 3 {
                let d = abs(Int(a.bytes[p * 4 + c]) - Int(b.bytes[p * 4 + c]))
                worst = max(worst, d)
                total += d
            }
            if worst > pixelThreshold {
                differing += 1
            }
        }
        let n = Double(a.width * a.height)
        return Difference(differingFraction: Double(differing) / n, meanDelta: Double(total) / (3 * n))
    }

    static func assertMatches(_ image: CGImage, named name: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let golden = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Goldens")
        guard !isRecording, let golden, let source = CGImageSourceCreateWithURL(golden as CFURL, nil),
              let expected = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            try write(image, to: sourceDirectory.appendingPathComponent("\(name).png"))
            Issue.record("Recorded golden \(name).png; review it and re-run", sourceLocation: sourceLocation)
            return
        }
        let diff = difference(RGBAPixels(image), RGBAPixels(expected))
        let matches = diff.map { $0.differingFraction <= maxDifferingFraction && $0.meanDelta <= maxMeanDelta } ?? false
        if !matches {
            let dir = URL(fileURLWithPath: "/tmp/InkEngineMetalSnapshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? write(image, to: dir.appendingPathComponent("\(name).png"))
        }
        #expect(
            matches,
            "\(name): \(diff.map { "\($0.differingFraction * 100)% pixels differ, mean Δ \($0.meanDelta)" } ?? "size mismatch")",
            sourceLocation: sourceLocation
        )
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Handwriting-like strokes for the pen goldens.
enum Handwriting {
    /// Pen, color and base width of a fixture stroke.
    struct Pen {
        var tool: PenKind
        var color: InkColor
        var width: Float
    }

    /// Loop row shape.
    struct Loops {
        var count = 4
        var advance: Float = 6.5
        var height: Float = 15
        var altitude: Float = 1.0
    }

    /// Cursive loops ("llll") with pen dynamics: heavier and slower on downstrokes, light and fast
    /// on upstrokes, like real writing.
    static func loops(_ id: UInt8, origin: CGPoint, pen: Pen, shape: Loops = Loops()) -> Stroke {
        let n = shape.count * 72
        var t: Float = 0
        var samples: [Sample] = []
        for i in 0 ... n {
            let theta = Float(i) / Float(n) * Float(shape.count) * 2 * .pi
            let down = max(0, -sin(theta)) // y grows (screen down) when sin < 0
            samples.append(Sample(
                x: Float(origin.x) + shape.advance * theta - 1.9 * shape.advance * sin(theta),
                y: Float(origin.y) - shape.height * cos(theta),
                force: 0.15 + 0.8 * down,
                altitude: shape.altitude,
                azimuth: 0.8,
                t: t
            ))
            t += (1 + 1.2 * down) / 240
        }
        return Stroke(id: RenderFixtures.strokeID(id), tool: pen.tool, color: pen.color, width: pen.width, samples: samples)
    }

    /// A gentle wave left to right with pressure 0.05 → 1 and the pen tilting from upright to 25°.
    static func ramp(_ id: UInt8, origin: CGPoint, length: Float, pen: Pen) -> Stroke {
        let n = 180
        let samples = (0 ... n).map { i in
            let u = Float(i) / Float(n)
            return Sample(
                x: Float(origin.x) + u * length,
                y: Float(origin.y) + 6 * sin(u * 3 * .pi),
                force: 0.05 + 0.95 * u,
                altitude: 1.5 - 1.06 * u,
                azimuth: 0.3,
                t: u * 0.9
            )
        }
        return Stroke(id: RenderFixtures.strokeID(id), tool: pen.tool, color: pen.color, width: pen.width, samples: samples)
    }

    /// A tight spiral (self-overlap, curvature) with a quick flick out.
    static func spiral(_ id: UInt8, center: CGPoint, pen: Pen) -> Stroke {
        let n = 220
        let samples = (0 ... n).map { i in
            let u = Float(i) / Float(n)
            let a = u * 5 * .pi
            let r = 3 + 22 * u
            return Sample(
                x: Float(center.x) + r * cos(a),
                y: Float(center.y) + r * sin(a),
                force: 0.75 - 0.5 * u,
                altitude: 1.1,
                azimuth: 0.8,
                t: u * (0.5 + 0.3 * u)
            )
        }
        return Stroke(id: RenderFixtures.strokeID(id), tool: pen.tool, color: pen.color, width: pen.width, samples: samples)
    }

    /// A small page for one pen kind: loops, a pressure/tilt ramp and a spiral.
    static func penPage(_ kind: PenKind, color: InkColor, width: Float) -> PageSnapshot {
        let pen = Pen(tool: kind, color: color, width: width)
        let fine = Pen(tool: kind, color: color, width: width * 0.6)
        let strokes = [
            loops(1, origin: CGPoint(x: 28, y: 44), pen: pen),
            loops(2, origin: CGPoint(x: 210, y: 44), pen: pen, shape: Loops(count: 3, advance: 4, height: 18, altitude: 0.6)),
            ramp(3, origin: CGPoint(x: 24, y: 104), length: 300, pen: pen),
            spiral(4, center: CGPoint(x: 60, y: 160), pen: pen),
            loops(5, origin: CGPoint(x: 120, y: 160), pen: fine, shape: Loops(count: 6, advance: 4.5, height: 9)),
        ]
        return PageSnapshot(
            page: Page(id: RenderFixtures.pageID(40), template: .blank, strokes: strokes),
            size: CGSize(width: 348, height: 200)
        )
    }

    /// Ink beneath highlighters in z-order, a self-crossing highlighter loop and two overlapping
    /// highlighters: ink must stay on top, the loop must not darken where it crosses itself.
    static var highlighterPage: PageSnapshot {
        let ink = [
            loops(1, origin: CGPoint(x: 28, y: 60), pen: Pen(tool: .fountain, color: .primary, width: 2.5), shape: Loops(count: 7)),
            ramp(2, origin: CGPoint(x: 24, y: 140), length: 300, pen: Pen(tool: .ballpoint, color: .semantic(.blue), width: 2)),
        ]
        let green = Pen(tool: .highlighter, color: .custom(RGBA8(rgba: 0x7ED9_57FF)), width: 12)
        func highlight(_ id: UInt8, _ a: CGPoint, _ b: CGPoint, width: Float) -> Stroke {
            RenderFixtures.line(id, from: a, to: b, tool: .highlighter, color: .semantic(.accent), width: width)
        }
        let highlights = [
            highlight(10, CGPoint(x: 20, y: 60), CGPoint(x: 330, y: 60), width: 18),
            loops(11, origin: CGPoint(x: 70, y: 140), pen: green, shape: Loops(count: 2, advance: 10, height: 22)),
            highlight(12, CGPoint(x: 200, y: 120), CGPoint(x: 330, y: 180), width: 14),
            highlight(13, CGPoint(x: 200, y: 180), CGPoint(x: 330, y: 120), width: 14),
        ]
        // Highlighters on top in z-order: the renderer must still draw them beneath the ink.
        return PageSnapshot(
            page: Page(id: RenderFixtures.pageID(41), template: .blank, strokes: ink + highlights),
            size: CGSize(width: 348, height: 200)
        )
    }
}
