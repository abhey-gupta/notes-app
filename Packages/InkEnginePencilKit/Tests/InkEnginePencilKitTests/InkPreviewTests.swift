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
            width: width ?? PencilKitConversion.referenceWidth(for: kind),
            color: RGBA8(r: 0x1E, g: 0x21, b: 0x29),
            pressure: pressure
        )
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

    /// The middle preset draws at PencilKit's default width for the ink, like the canvas (the highlighter's
    /// band at its toolbar width, #120).
    @Test(arguments: kinds)
    func neutralPressureDrawsAtThePencilKitWidth(kind: PenKind) {
        let widths = InkPreview.pointWidths(Self.spec(kind, pressure: false))
        let expected = kind == .highlighter
            ? CGFloat(PencilKitConversion.referenceWidth(for: kind)) : PencilKitConversion.inkType(for: kind).defaultWidth
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
        let widths = [Float](arrayLiteral: 1.5, 2.5, 4, 6, 8).map { width in
            InkPreview.pointWidths(Self.spec(.ballpoint, width: width, pressure: false))[0]
        }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
    }

    /// Bold inks shrink to fit; fine pens draw true size.
    @Test func boldInksScaleDown() {
        #expect(InkPreview.fit(Self.spec(.ballpoint), in: Self.size) == 1)
        #expect(InkPreview.fit(Self.spec(.brush), in: Self.size) < 1)
    }

    @Test(arguments: kinds)
    func imageIsPreviewSizedAndInked(kind: PenKind) throws {
        let image = InkPreview.image(Self.spec(kind), size: Self.size, scale: 2)
        let cg = try #require(image.cgImage)
        #expect(abs(cg.width - 592) <= 1)
        #expect(abs(cg.height - 144) <= 1)
        #expect(Self.inkedPixels(cg) > 500)
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
