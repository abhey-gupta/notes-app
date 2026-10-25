import CoreGraphics
import Document
import Foundation
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

/// PencilKit strokes as the canvas captures them must come back from the model and the file format
/// exactly: same control points, ink and seed, same pixels (#71).
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct LosslessRoundTripTests {
    /// Colors exactly representable in 8-bit sRGB, so `.custom(RGBA8)` round-trips them.
    private static let colors: [UIColor] = [
        UIColor(RGBA8(rgba: 0x1E21_29FF)), UIColor(RGBA8(rgba: 0x2C4F_D6FF)), UIColor(RGBA8(rgba: 0xF5D0_4AFF)),
    ]

    /// Strokes with everything PencilKit varies per point: non-square sizes, opacity, force, tilt.
    static func capturedLikeStrokes(seed: UInt64 = 1) -> [PKStroke] {
        var rng = SystemRandomNumberGeneratorSeeded(seed: seed)
        let inks: [PKInk.InkType] = [.pen, .fountainPen, .marker, .monoline, .pencil, .watercolor, .crayon]
        return inks.enumerated().map { i, type in
            let n = 40 + i * 7
            let y0 = 60 + CGFloat(i) * 100
            let points = (0 ..< n).map { j -> PKStrokePoint in
                let u = CGFloat(j) / CGFloat(n - 1)
                let w = CGFloat.random(in: 1 ... 14, using: &rng)
                let location = CGPoint(x: 40 + 480 * u, y: y0 + 30 * sin(u * 9) + CGFloat.random(in: -2 ... 2, using: &rng))
                let size = CGSize(width: w, height: i.isMultiple(of: 2) ? w : w * CGFloat.random(in: 0.3 ... 1.5, using: &rng))
                let (opacity, force) = (CGFloat.random(in: 0.4 ... 1, using: &rng), CGFloat.random(in: 0 ... 4, using: &rng))
                let (azimuth, altitude) = (CGFloat.random(in: -3 ... 3, using: &rng), CGFloat.random(in: 0.3 ... 1.57, using: &rng))
                // Ink-specific fields, as live watercolor strokes set them (wash scale ~0.83).
                let secondary = CGFloat.random(in: 0.6 ... 1, using: &rng)
                let (threshold, jitter) = (CGFloat.random(in: 0 ... 1, using: &rng), CGFloat.random(in: 0 ... 1, using: &rng))
                guard #available(iOS 27, *) else {
                    return PKStrokePoint(
                        location: location, timeOffset: TimeInterval(j) / 240, size: size, opacity: opacity, force: force,
                        azimuth: azimuth, altitude: altitude, secondaryScale: secondary, threshold: threshold
                    )
                }
                return PKStrokePoint(
                    location: location, timeOffset: TimeInterval(j) / 240, size: size, opacity: opacity, force: force,
                    azimuth: azimuth, altitude: altitude, secondaryScale: secondary, threshold: threshold, lateralJitter: jitter
                )
            }
            var stroke = PKStroke(
                ink: PKInk(type, color: colors[i % colors.count]),
                path: PKStrokePath(controlPoints: points, creationDate: Date()),
                randomSeed: UInt32.random(in: 0 ... .max, using: &rng)
            )
            // Live watercolor strokes come with a render group; textured inks may carry a grain offset.
            if #available(iOS 27, *), [.watercolor, .crayon, .pencil].contains(type) {
                stroke.renderGroupID = UUID()
                if type != .watercolor {
                    stroke.renderState = PKStroke.RenderState(grainOffset: CGPoint(x: 3.25, y: -7.5))
                }
            }
            // What PencilKit hands back after storing (it quantizes some fields).
            return PKDrawing(strokes: [stroke]).strokes[0]
        }
    }

    private static func model(_ pk: PKStroke) -> Stroke {
        PencilKitConversion.stroke(from: pk, color: .custom(RGBA8(pk.ink.color)), width: 2.5)
    }

    /// The stroke as PencilKit holds it in a drawing (the canvas and rasters draw `PKDrawing`s, which
    /// quantize some fields only when they take the stroke).
    private static func back(_ stroke: Stroke) -> PKStroke {
        guard case let .custom(rgba) = stroke.color else { return PencilKitConversion.pkStroke(from: stroke, color: .black) }
        return PKDrawing(strokes: [PencilKitConversion.pkStroke(from: stroke, color: UIColor(rgba))]).strokes[0]
    }

    private static func expectSamePoints(_ a: PKStroke, _ b: PKStroke) {
        #expect(a.ink.inkType == b.ink.inkType)
        #expect(a.randomSeed == b.randomSeed)
        #expect(a.transform == b.transform)
        if #available(iOS 27, *) {
            #expect(a.renderGroupID == b.renderGroupID)
            #expect(a.renderState == b.renderState)
        }
        #expect(a.path.count == b.path.count)
        for (p, q) in zip(a.path, b.path) {
            #expect(p.location == q.location)
            #expect(p.size == q.size)
            #expect(p.opacity == q.opacity)
            #expect(p.force == q.force)
            #expect(p.azimuth == q.azimuth)
            #expect(p.altitude == q.altitude)
            #expect(p.timeOffset == q.timeOffset)
            #expect(p.secondaryScale == q.secondaryScale)
            #expect(p.threshold == q.threshold)
            if #available(iOS 27, *) {
                #expect(p.lateralJitter == q.lateralJitter)
            }
        }
    }

    @Test func pencilKitStrokeModelPencilKitIsExact() {
        for pk in Self.capturedLikeStrokes() {
            let stroke = Self.model(pk)
            #expect(stroke.rendering?.ink == pk.ink.inkType.rawValue)
            Self.expectSamePoints(Self.back(stroke), pk)
        }
    }

    @Test func throughStrokeFileRendersPixelIdentical() throws {
        let original = Self.capturedLikeStrokes(seed: 2)
        let decoded = try StrokeCodec.decode(StrokeCodec.encode(original.map(Self.model)))
        let restored = decoded.map(Self.back)
        for (a, b) in zip(restored, original) {
            Self.expectSamePoints(a, b)
        }
        let rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let before = try #require(PKDrawing(strokes: original).image(from: rect, scale: 2).cgImage)
        let after = try #require(PKDrawing(strokes: restored).image(from: rect, scale: 2).cgImage)
        #expect(Pixels(before).differingPixels(from: Pixels(after)) == 0)
        #expect(Pixels(before).inkedPixels > 10000) // the comparison saw real ink
    }

    @Test func throughJournalAndCheckpointRendersPixelIdentical() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "Lossless-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notebook = Notebook(title: "RT", pages: [PageID()])
        let package = try NotebookPackage.create(at: dir.appending(path: "rt.nb"), notebook: notebook)
        let id = notebook.pages[0]
        let original = Self.capturedLikeStrokes(seed: 3)
        let strokes = original.map(Self.model)

        let store = try DocumentStore(opening: package.url, options: .init(idleDelay: nil))
        for stroke in strokes {
            try await store.apply(store.page(id).addEdit([stroke]), to: id)
        }
        // Journal replay (no checkpoint), then checkpointed stroke file.
        let replayed = try await DocumentStore(opening: package.url, options: .init(idleDelay: nil)).page(id).strokes
        #expect(replayed == strokes)
        try await store.flush()
        let reloaded = try NotebookPackage.open(at: package.url).loadPage(id).strokes
        #expect(reloaded == strokes)
        for (a, b) in zip(reloaded.map(Self.back), original) {
            Self.expectSamePoints(a, b)
        }
    }

    @Test func rasterOfStoredStrokesMatchesCanvasDrawing() throws {
        // The inactive-page raster draws the model strokes; it must equal PencilKit's image of what was
        // captured (light appearance, as the canvas is pinned to).
        let original = Self.capturedLikeStrokes(seed: 4)
        let page = Page(strokes: original.map(Self.model))
        let snapshot = PageSnapshot(page: page, size: CGSize(width: 595, height: 842))
        let job = RenderJob(page: snapshot, palette: FixturePalette(), theme: .white)
        let raster = try #require(job.ink(scale: 2))
        let rect = CGRect(x: 0, y: 0, width: 595, height: 842)
        var expected: CGImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            expected = PKDrawing(strokes: original).image(from: rect, scale: 2).cgImage
        }
        #expect(try Pixels(raster).differingPixels(from: Pixels(#require(expected))) == 0)
    }

    @Test func rasterIgnoresDarkAppearance() throws {
        let original = Self.capturedLikeStrokes(seed: 5)
        let snapshot = PageSnapshot(page: Page(strokes: original.map(Self.model)), size: CGSize(width: 595, height: 842))
        let job = RenderJob(page: snapshot, palette: FixturePalette(), theme: .white)
        let light = try #require(job.ink(scale: 1))
        var dark: CGImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { dark = job.ink(scale: 1) }
        #expect(try Pixels(light).differingPixels(from: Pixels(#require(dark))) == 0)
    }

    @Test func derivedRenderingIsDeterministic() throws {
        // v1 strokes (no stored rendering) render the same every time: seed comes from the stroke ID.
        let stroke = Stroke(
            tool: .brush, color: .primary, width: 6,
            samples: (0 ..< 30).map { Sample(x: 50 + Float($0) * 10, y: 100, force: 0.6) }
        )
        let a = PencilKitConversion.pkStroke(from: stroke, color: .black)
        let b = PencilKitConversion.pkStroke(from: stroke, color: .black)
        #expect(a.randomSeed == b.randomSeed)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ia = try #require(PKDrawing(strokes: [a]).image(from: rect, scale: 2).cgImage)
        let ib = try #require(PKDrawing(strokes: [b]).image(from: rect, scale: 2).cgImage)
        #expect(Pixels(ia).differingPixels(from: Pixels(ib)) == 0)
    }
}

/// RGBA8 pixels of an image, for exact comparisons.
@Suite(.timeLimit(.minutes(2)))
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        bytes = pixels
    }

    func differingPixels(from other: Pixels) -> Int {
        guard width == other.width, height == other.height else { return .max }
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) where bytes[i ..< i + 4] != other.bytes[i ..< i + 4] {
            count += 1
        }
        return count
    }

    var inkedPixels: Int {
        stride(from: 3, to: bytes.count, by: 4).reduce(0) { $0 + (bytes[$1] > 0 ? 1 : 0) }
    }
}

/// Deterministic generator for test data.
struct SystemRandomNumberGeneratorSeeded: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
