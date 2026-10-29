import CoreGraphics
@testable import InkEnginePencilKit
import InkGeometry
import InkModel
import PencilKit
import Testing
import UIKit

/// PencilKit does not draw a `PKStrokePoint` as wide as its `size`: each ink maps the size to its own
/// mark (`InkNib`). These pin the map against PencilKit itself, so hit tests, the eraser and PDF export
/// (all on `Centerline(stroke:)`) stay as wide as the ink on screen (`PKDrawing.image` is what the
/// canvas and the inactive-page raster show; `LosslessRoundTripTests`, `InkFidelityTests`).
///
/// Thickness is measured across straight strokes: alpha coverage per column (opaque inks) or the
/// rows above 25 % alpha (translucent marker and wash, whose visible edge is what matters).
///
/// Serialized: PencilKit's renderer sets up shared Metal resources (paper textures) lazily, and
/// concurrent first renders have deadlocked it in the simulator.
@Suite(.serialized, .timeLimit(.minutes(5)))
@MainActor
struct InkWidthTests {
    struct Case: CustomStringConvertible, Sendable {
        /// `PKInk.InkType` raw value (the type itself is not Sendable).
        var ink: String
        var size: CGFloat
        var aspect: CGFloat = 1
        var azimuth: CGFloat = 0
        var secondary: CGFloat = 1
        var opacity: CGFloat = 1
        var vertical = false
        var byEdge = false

        var description: String {
            "\(ink) size \(size)×\(aspect) az \(azimuth) sec \(secondary) op \(opacity) \(vertical ? "V" : "H")"
        }
    }

    nonisolated static let cases: [Case] = [
        Case(ink: StrokeRendering.Ink.pen, size: 2.5), Case(ink: StrokeRendering.Ink.pen, size: 3.1), Case(
            ink: StrokeRendering.Ink.pen,
            size: 6,
            vertical: true
        ), Case(ink: StrokeRendering.Ink.pen, size: 20),
        Case(ink: StrokeRendering.Ink.monoline, size: 4), Case(ink: StrokeRendering.Ink.monoline, size: 10, vertical: true),
        // Fountain pen: a chisel along the azimuth (thin along the stroke, thick across, chord between).
        Case(ink: StrokeRendering.Ink.fountainPen, size: 3.2), Case(ink: StrokeRendering.Ink.fountainPen, size: 10), Case(
            ink: StrokeRendering.Ink.fountainPen,
            size: 10,
            azimuth: .pi / 2
        ),
        Case(ink: StrokeRendering.Ink.fountainPen, size: 10, azimuth: .pi / 4), Case(
            ink: StrokeRendering.Ink.fountainPen,
            size: 10,
            azimuth: .pi,
            vertical: true
        ),
        Case(ink: StrokeRendering.Ink.fountainPen, size: 20, azimuth: -.pi / 2),
        // Marker as the highlighter captures it (opacity 1.5, secondary 0.07) and plain.
        Case(ink: StrokeRendering.Ink.marker, size: 13.75, azimuth: .pi / 2, secondary: 0.07, opacity: 1.5, byEdge: true),
        Case(ink: StrokeRendering.Ink.marker, size: 13.75, azimuth: 0, secondary: 0.07, opacity: 1.5, byEdge: true),
        Case(ink: StrokeRendering.Ink.marker, size: 20, azimuth: .pi / 2, byEdge: true), Case(
            ink: StrokeRendering.Ink.marker,
            size: 6,
            azimuth: 0,
            vertical: true,
            byEdge: true
        ),
        Case(ink: StrokeRendering.Ink.marker, size: 10, aspect: 2, azimuth: .pi / 2, byEdge: true),
        // Watercolor: round, scaled by the wash (secondaryScale); opacity only thins the coverage.
        Case(ink: StrokeRendering.Ink.watercolor, size: 4), Case(ink: StrokeRendering.Ink.watercolor, size: 10, vertical: true), Case(
            ink: StrokeRendering.Ink.watercolor,
            size: 20
        ),
        Case(ink: StrokeRendering.Ink.watercolor, size: 10.3, secondary: 0.83, opacity: 0.18, byEdge: true),
        Case(ink: StrokeRendering.Ink.watercolor, size: 10, secondary: 0.5),
        Case(ink: StrokeRendering.Ink.pencil, size: 3), Case(ink: StrokeRendering.Ink.pencil, size: 10), Case(
            ink: StrokeRendering.Ink.crayon,
            size: 4
        ), Case(ink: StrokeRendering.Ink.crayon, size: 10),
    ]

    static func stroke(_ c: Case) -> PKStroke {
        let n = 80
        let points = (0 ..< n).map { j -> PKStrokePoint in
            let u = CGFloat(j) / CGFloat(n - 1)
            let location = c.vertical ? CGPoint(x: 100, y: 40 + 320 * u) : CGPoint(x: 40 + 320 * u, y: 100)
            return PKStrokePoint(
                location: location, timeOffset: TimeInterval(j) / 240, size: CGSize(width: c.size, height: c.size * c.aspect),
                opacity: c.opacity, force: 1, azimuth: c.azimuth, altitude: .pi / 2, secondaryScale: c.secondary, threshold: 0
            )
        }
        let type = PKInk.InkType(rawValue: c.ink) ?? .pen
        return PKStroke(ink: PKInk(type, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()), randomSeed: 7)
    }

    /// Mean thickness (pt) over the middle cross-sections of a straight stroke.
    static func drawnThickness(_ strokes: [PKStroke], vertical: Bool, byEdge: Bool, scale: CGFloat = 4) -> Double {
        let side: CGFloat = 400
        var image: CGImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = PKDrawing(strokes: strokes).image(from: CGRect(x: 0, y: 0, width: side, height: side), scale: scale).cgImage
        }
        guard let image else { return -1 }
        let px = Pixels(image)
        var total = 0.0
        let a0 = Int(120 * scale)
        let a1 = Int(280 * scale)
        for a in a0 ..< a1 {
            for b in 0 ..< (vertical ? px.width : px.height) {
                let (x, y) = vertical ? (b, a) : (a, b)
                let alpha = Double(px.bytes[(y * px.width + x) * 4 + 3]) / 255
                if byEdge {
                    total += alpha > 0.25 ? 1 : 0
                } else {
                    total += alpha
                }
            }
        }
        return total / Double(a1 - a0) / Double(scale)
    }

    /// Our width for the same stroke, through the model: `2 × Centerline.radii` at the middle.
    static func modelThickness(_ pk: PKStroke) -> Double {
        let centerline = Centerline(stroke: PencilKitConversion.stroke(from: pk))
        return 2 * Double(centerline.radii[centerline.radii.count / 2])
    }

    @Test(arguments: cases)
    func centerlineIsAsWideAsPencilKitDraws(c: Case) {
        let pk = Self.stroke(c)
        let drawn = Self.drawnThickness([pk], vertical: c.vertical, byEdge: c.byEdge)
        let model = Self.modelThickness(pk)
        // 5 %, plus a pixel's worth for thin lines and the textured inks' ragged edges.
        let slack = c.ink == StrokeRendering.Ink.pencil || c.ink == StrokeRendering.Ink.crayon ? 0.3 : 0.12
        #expect(abs(model - drawn) <= 0.05 * drawn + slack, "\(c): model \(model) vs PencilKit \(drawn)")
    }

    /// Azimuth runs from +x toward +y: a fountain nib at +45° lies along the (1, 1) diagonal, so a
    /// stroke down that diagonal is the thin side (`InkGeometry`'s heading math agrees).
    @Test func azimuthDirection() {
        func diagonal(azimuth: CGFloat, down: Bool) -> PKStroke {
            let n = 120
            let points = (0 ..< n).map { j -> PKStrokePoint in
                let u = CGFloat(j) / CGFloat(n - 1)
                let location = CGPoint(x: 40 + 320 * u, y: down ? 40 + 320 * u : 360 - 320 * u)
                return PKStrokePoint(
                    location: location, timeOffset: TimeInterval(j) / 240, size: CGSize(width: 10, height: 10), opacity: 1,
                    force: 1, azimuth: azimuth, altitude: .pi / 2, secondaryScale: 1, threshold: 0
                )
            }
            let path = PKStrokePath(controlPoints: points, creationDate: Date())
            return PKStroke(ink: PKInk(.fountainPen, color: .black), path: path, randomSeed: 7)
        }
        func area(_ pk: PKStroke) -> Double {
            var image: CGImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                image = PKDrawing(strokes: [pk]).image(from: CGRect(x: 0, y: 0, width: 400, height: 400), scale: 4).cgImage
            }
            guard let image else { return -1 }
            let px = Pixels(image)
            return stride(from: 3, to: px.bytes.count, by: 4).reduce(0.0) { $0 + Double(px.bytes[$1]) / 255 } / 16
        }
        let length = 320.0 * 2.0.squareRoot()
        for (azimuth, down, expected) in [
            (CGFloat.pi / 4, true, 4.0),
            (.pi / 4, false, 16.0),
            (-.pi / 4, true, 16.0),
            (-.pi / 4, false, 4.0),
        ] {
            let pk = diagonal(azimuth: azimuth, down: down)
            let drawn = area(pk) / length
            #expect(abs(drawn - expected) <= 0.1 * expected + 0.3, "az \(azimuth) \(down ? "down" : "up"): \(drawn)")
            #expect(abs(Self.modelThickness(pk) - expected) <= 1e-3)
        }
    }

    /// The derived rendering (v1 strokes, fixtures) draws at the profile width on screen.
    @Test func derivedRenderingDrawsAtProfileWidth() {
        let samples = (0 ..< 80).map { j in Sample(x: 40 + 320 * Float(j) / 79, y: 100, force: 0.5, t: Float(j) / 240) }
        for (tool, width): (PenKind, Float) in [(.ballpoint, 2.5), (.ballpoint, 4), (.ballpoint, 8), (.brush, 6)] {
            let stroke = Stroke(tool: tool, color: .primary, width: width, samples: samples)
            let pk = PencilKitConversion.pkStroke(from: stroke, color: .black)
            let drawn = Self.drawnThickness([pk], vertical: false, byEdge: false)
            let expected = Double(width * PenProfile(tool).widthScale(force: 0.5, speed: 0, altitude: .pi / 2))
            #expect(abs(drawn - expected) <= 0.05 * expected + 0.12, "\(tool) \(width): \(drawn) vs \(expected)")
        }
    }
}
