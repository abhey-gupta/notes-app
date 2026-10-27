import CoreGraphics
@testable import InkEnginePencilKit
import InkModel
import PencilKit
import Testing
import UIKit

@Suite(.timeLimit(.minutes(2)))
struct InkPreviewTests {
    static let size = CGSize(width: 296, height: 72)
    static let kinds: [PenKind] = [.fountain, .ballpoint, .brush, .highlighter]

    static func spec(_ kind: PenKind, width: Float? = nil, pressure: Bool = true) -> InkPreview.Spec {
        InkPreview.Spec(
            kind: kind,
            width: width ?? defaultWidth(kind),
            color: RGBA8(r: 0x1E, g: 0x21, b: 0x29),
            pressure: pressure
        )
    }

    /// Fresh-install widths (pt): 0.5 mm pens, 8 mm brush, 5.5 mm highlighter.
    static func defaultWidth(_ kind: PenKind) -> Float {
        kind == .highlighter ? 15.6 : kind == .brush ? 22.7 : 1.42
    }

    @Test(arguments: kinds)
    func strokeUsesTheToolsInkAndFitsThePreview(kind: PenKind) {
        let spec = Self.spec(kind)
        let fit = InkPreview.fit(spec, in: Self.size)
        let space = CGRect(x: 0, y: 0, width: Self.size.width / fit, height: Self.size.height / fit)
        let stroke = InkPreview.stroke(spec, in: Self.size)
        #expect(stroke.ink.inkType == PencilKitConversion.inkType(for: kind))
        #expect(stroke.path.count == InkPreview.pointCount)
        for point in stroke.path {
            let r = point.size.width / 2
            #expect(space.contains(CGRect(x: point.location.x - r, y: point.location.y - r, width: 2 * r, height: 2 * r)))
        }
    }

    /// Neutral pressure draws at the canvas's tool width (the highlighter's band at its width, #120).
    @Test(arguments: kinds)
    func neutralPressureDrawsAtThePencilKitWidth(kind: PenKind) {
        let widths = InkPreview.pointWidths(Self.spec(kind, pressure: false))
        let expected = PencilKitConversion.pencilKitWidth(for: kind, width: Self.defaultWidth(kind))
        #expect(widths.allSatisfy { abs($0 - expected) < 1e-3 })
    }

    @Test func pressureTapersTheEnds() {
        let widths = InkPreview.pointWidths(Self.spec(.fountain))
        let middle = widths[widths.count / 2]
        #expect(widths[0] < middle)
        #expect(widths[widths.count - 1] < middle)
        #expect(Set(widths).count > 10)
    }

    @Test func widerPresetsDrawWider() {
        let widths = [Float](arrayLiteral: 0.28, 0.85, 1.42, 2.8, 5.7).map { width in
            InkPreview.pointWidths(Self.spec(.ballpoint, width: width, pressure: false))[0]
        }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
    }

    /// Bold inks shrink to fit; fine pens draw true size.
    @Test func boldInksScaleDown() {
        #expect(InkPreview.fit(Self.spec(.ballpoint), in: Self.size) == 1)
        #expect(InkPreview.fit(Self.spec(.brush, width: 57), in: Self.size) < 1)
    }

    /// Every size shows ink, down to 0.1 mm (#168: the two finest presets drew an empty preview).
    @Test(arguments: [
        (PenKind.ballpoint, Float(0.28)),
        (.fountain, 0.28),
        (.ballpoint, 1.42),
        (.fountain, 1.42),
        (.brush, 22.7),
        (.highlighter, 15.6)
    ])
    func imageIsPreviewSizedAndInked(kind: PenKind, width: Float) throws {
        let image = InkPreview.image(Self.spec(kind, width: width), size: Self.size, scale: 2)
        let cg = try #require(image.cgImage)
        #expect(abs(cg.width - 592) <= 1)
        #expect(abs(cg.height - 144) <= 1)
        #expect(Self.inkedPixels(cg) > 200, "\(kind) \(width) pt")
    }

    private static func inkedPixels(_ image: CGImage) -> Int {
        let (w, h) = (image.width, image.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return stride(from: 3, to: bytes.count, by: 4).count { bytes[$0] > 32 }
    }
}
