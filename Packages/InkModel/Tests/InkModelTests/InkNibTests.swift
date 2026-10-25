@testable import InkModel
import Testing

/// What PencilKit paints per stored point size (measured; see `InkNib` and InkEnginePencilKitTests'
/// `InkWidthTests`).
struct InkNibTests {
    private func nib(_ ink: String, _ w: Float, _ h: Float? = nil, secondary: Double = 1) -> InkNib {
        InkNib(ink: ink, point: PointRendering(width: w, height: h ?? w, secondaryScale: secondary))
    }

    @Test func penIsRoundTwiceTheSizeLessFour() {
        #expect(nib(StrokeRendering.Ink.pen, 10) == InkNib(along: 16, across: 16))
        #expect(nib(StrokeRendering.Ink.pen, 3, 1) == InkNib(along: 2, across: 2)) // height ignored
        #expect(nib(StrokeRendering.Ink.pen, 1.5).maximumWidth == 0) // nothing below 2
        #expect(nib(StrokeRendering.Ink.monoline, 6) == nib(StrokeRendering.Ink.pen, 6))
        #expect(nib(StrokeRendering.Ink.pen, 10).isRound)
    }

    @Test func fountainPenIsAFourToOneChisel() {
        let n = nib(StrokeRendering.Ink.fountainPen, 10)
        #expect(n == InkNib(along: 16, across: 4))
        #expect(!n.isRound && n.maximumWidth == 16)
    }

    @Test func markerIsAChiselOfBothSides() {
        let n = nib(StrokeRendering.Ink.marker, 13.75)
        #expect(abs(n.along - 19.4375) < 1e-4 && abs(n.across - 7.325) < 1e-4)
        #expect(nib(StrokeRendering.Ink.marker, 10, 20).along > nib(StrokeRendering.Ink.marker, 10, 10).along)
    }

    @Test func watercolorWashShrinksWithSecondaryScale() {
        #expect(abs(nib(StrokeRendering.Ink.watercolor, 10).along - 16.3) < 1e-4)
        #expect(abs(nib(StrokeRendering.Ink.watercolor, 10, secondary: 0.83).along - 14.027) < 1e-3)
        #expect(nib(StrokeRendering.Ink.watercolor, 10).isRound)
    }

    @Test func unknownInkAndBadSizesFallBack() {
        #expect(nib("com.example.ink", 3, 5) == InkNib(along: 5, across: 5))
        #expect(nib(StrokeRendering.Ink.pen, .nan) == InkNib(along: 1, across: 1))
    }

    @Test(arguments: [
        StrokeRendering.Ink.pen, StrokeRendering.Ink.monoline, StrokeRendering.Ink.fountainPen, StrokeRendering.Ink.marker,
        StrokeRendering.Ink.watercolor, StrokeRendering.Ink.pencil, StrokeRendering.Ink.crayon, "com.example.ink",
    ])
    func pointSizeInvertsTheNibAlongTheAzimuth(ink: String) {
        for width: Float in [0.5, 1, 2.5, 4, 16, 40] {
            let size = InkNib.pointSize(ink: ink, width: width)
            let drawn = InkNib(ink: ink, point: PointRendering(width: size, height: size)).along
            #expect(abs(drawn - width) < 1e-4, "\(ink) \(width) → \(size) → \(drawn)")
        }
    }

    @Test func maximumDrawnWidthIsTheWidestMark() {
        let rendering = StrokeRendering(ink: StrokeRendering.Ink.fountainPen, randomSeed: 0, points: [
            PointRendering(width: 4, height: 4), PointRendering(width: 10, height: 10), PointRendering(width: 6, height: 6),
        ])
        #expect(rendering.maximumDrawnWidth == 16)
        #expect(StrokeRendering(ink: StrokeRendering.Ink.pen, randomSeed: 0, points: []).maximumDrawnWidth == 0)
    }
}
