import CoreGraphics
import InkEngine
@testable import InkEngineMetal
import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing

/// Same fixtures through both engines (ARCHITECTURE.md §13): the looks differ by design (our pen
/// profiles vs PencilKit's inks), but the ink must land in the same places at about the same size.
@MainActor
struct CrossCheckTests {
    struct Agreement {
        /// Fraction of Metal ink pixels within `radius` px of PencilKit ink, and vice versa.
        var metalInPencilKit: Double
        var pencilKitInMetal: Double
        var metalPixels: Int
        var pencilKitPixels: Int
    }

    func agreement(_ page: PageSnapshot, scale: CGFloat = 1, radius: Int = 3) async throws -> Agreement {
        let metal = try #require(MetalInkEngine(palette: FixturePalette()))
        let pencilKit = PencilKitInkEngine(palette: FixturePalette())
        let a = try RGBAPixels(#require(await metal.render(page: page, size: page.size, scale: scale)))
        let b = try RGBAPixels(#require(await pencilKit.render(page: page, size: page.size, scale: scale)))
        #expect(a.width == b.width && a.height == b.height)
        let paper = FixturePalette().paper(.white)
        let ma = a.mask(differingFrom: paper)
        let mb = b.mask(differingFrom: paper)
        let da = dilate(ma, width: a.width, height: a.height, radius: radius)
        let db = dilate(mb, width: b.width, height: b.height, radius: radius)
        func fraction(_ mask: [Bool], within other: [Bool]) -> Double {
            let inside = zip(mask, other).count(where: { $0 && $1 })
            return Double(inside) / Double(max(mask.count(where: \.self), 1))
        }
        return Agreement(
            metalInPencilKit: fraction(ma, within: db),
            pencilKitInMetal: fraction(mb, within: da),
            metalPixels: ma.count(where: \.self),
            pencilKitPixels: mb.count(where: \.self)
        )
    }

    @Test func allPensFixtureAgreesWithPencilKit() async throws {
        let result = try await agreement(RenderFixtures.allPens)
        #expect(result.metalPixels > 2000)
        #expect(result.metalInPencilKit > 0.9, "\(result)")
        #expect(result.pencilKitInMetal > 0.9, "\(result)")
        // Similar amount of ink overall (catches gross width errors).
        let ratio = Double(result.metalPixels) / Double(max(result.pencilKitPixels, 1))
        #expect(ratio > 0.6 && ratio < 1.6, "\(result)")
    }

    @Test(arguments: [PenKind.fountain, .ballpoint])
    func handwritingAgreesWithPencilKit(_ kind: PenKind) async throws {
        let result = try await agreement(Handwriting.penPage(kind, color: .primary, width: 3), scale: 2, radius: 4)
        #expect(result.metalInPencilKit > 0.85, "\(result)")
        #expect(result.pencilKitInMetal > 0.85, "\(result)")
    }

    private func dilate(_ mask: [Bool], width: Int, height: Int, radius r: Int) -> [Bool] {
        // Separable square dilation: rows, then columns.
        var rows = [Bool](repeating: false, count: mask.count)
        for y in 0 ..< height {
            for x in 0 ..< width where mask[y * width + x] {
                for dx in max(x - r, 0) ... min(x + r, width - 1) {
                    rows[y * width + dx] = true
                }
            }
        }
        var out = [Bool](repeating: false, count: mask.count)
        for y in 0 ..< height {
            for x in 0 ..< width where rows[y * width + x] {
                for dy in max(y - r, 0) ... min(y + r, height - 1) {
                    out[dy * width + x] = true
                }
            }
        }
        return out
    }
}
