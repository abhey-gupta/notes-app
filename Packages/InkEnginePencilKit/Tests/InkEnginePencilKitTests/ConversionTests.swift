import CoreGraphics
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkGeometry
import InkModel
import PencilKit
import Testing
import UIKit

@Suite(.timeLimit(.minutes(2)))
struct ConversionTests {
    @Test(arguments: PenKind.allCases)
    func strokeRoundTripPreservesSamplesAndBounds(kind: PenKind) {
        let original = RenderFixtures.wave(1, origin: CGPoint(x: 40, y: 300), tool: kind)
        let pk = PencilKitConversion.pkStroke(from: original, color: .black)
        #expect(pk.path.count == original.samples.count)
        #expect(pk.ink.inkType == PencilKitConversion.inkType(for: kind))

        let back = PencilKitConversion.stroke(from: pk, id: original.id, color: original.color, width: original.width)
        #expect(back.id == original.id)
        #expect(back.tool == kind)
        #expect(back.samples.count == original.samples.count)
        #expect(back.width == original.width)
        #expect(back.rendering?.points.map(\.width) == original.derivedRendering.points.map(\.width))
        for edge in [\CGRect.minX, \.minY, \.maxX, \.maxY] {
            #expect(abs(back.bounds[keyPath: edge] - original.bounds[keyPath: edge]) <= 0.5)
        }
        for (a, b) in zip(back.samples, original.samples) {
            #expect(abs(a.x - b.x) < 1e-4)
            #expect(abs(a.y - b.y) < 1e-4)
            #expect(abs(a.force - b.force) < 1e-3) // PencilKit keeps force to 3 decimals (UITouch units)
            #expect(abs(a.altitude - b.altitude) < 1e-4)
            #expect(abs(a.azimuth - b.azimuth) < 1e-4)
            #expect(abs(a.t - b.t) < 1e-5)
        }
    }

    @Test func pointSizeFollowsPenProfile() {
        let stroke = RenderFixtures.wave(1, origin: .zero, tool: .fountain)
        let pk = PencilKitConversion.pkStroke(from: stroke, color: .black)
        let sizes = pk.path.map(\.size.width)
        #expect(sizes.first ?? 0 < sizes.last ?? 0) // pressure rises along the fixture
    }

    @Test func transformIsBakedIntoSamples() {
        let stroke = RenderFixtures.line(1, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 10), width: 4)
        var pk = PencilKitConversion.pkStroke(from: stroke, color: .black)
        pk.transform = CGAffineTransform(translationX: 100, y: 5).scaledBy(x: 2, y: 2)
        let back = PencilKitConversion.stroke(from: pk, color: .primary)
        #expect(back.samples.first?.x == 120)
        #expect(back.samples.first?.y == 25)
        #expect(back.samples.last?.x == 200)
        #expect(abs(back.width - 8) < 1e-3)
    }

    @Test func colorDefaultsToInkColor() {
        let stroke = RenderFixtures.line(1, from: .zero, to: CGPoint(x: 10, y: 0))
        let pk = PencilKitConversion.pkStroke(from: stroke, color: UIColor(RGBA8(rgba: 0x2C4F_D6FF)))
        #expect(PencilKitConversion.stroke(from: pk).color == .custom(RGBA8(rgba: 0x2C4F_D6FF)))
    }

    @Test(arguments: PenKind.allCases)
    func penKindInkTypeRoundTrip(kind: PenKind) {
        #expect(PencilKitConversion.penKind(for: PencilKitConversion.inkType(for: kind)) == kind)
    }

    @Test func inkingToolClampsWidth() {
        let tool = PencilKitConversion.inkingTool(.ballpoint, color: .black, width: 10000)
        #expect(tool.width <= PKInk.InkType.pen.validWidthRange.upperBound)
    }

    @Test(arguments: PenKind.allCases)
    func referenceWidthDrawsAtPencilKitDefaultAndPresetsStepUp(kind: PenKind) {
        let type = PencilKitConversion.inkType(for: kind)
        let reference = PencilKitConversion.referenceWidth(for: kind)
        #expect(PencilKitConversion.pencilKitWidth(for: kind, width: reference) == type.defaultWidth)
        // Presets step strictly finer → bolder within the ink's range.
        let presets: [Float] = kind == .highlighter ? [10, 16, 24] : [1.5, 2.5, 4, 6, 8]
        let widths = presets.map { PencilKitConversion.pencilKitWidth(for: kind, width: $0) }
        #expect(widths == widths.sorted())
        #expect(Set(widths).count == widths.count)
        #expect(widths.allSatisfy { type.validWidthRange.contains($0) })
    }

    /// The default pen (preset 2.5) is a fine pen, not PencilKit's bolder default, and the finest
    /// preset is at or near the ink's minimum (real-iPad feedback: default fountain read marker-thick).
    @Test(arguments: [PenKind.ballpoint, .fountain])
    func defaultPresetIsAFinePen(kind: PenKind) {
        let range = PencilKitConversion.inkType(for: kind).validWidthRange
        let fine = PencilKitConversion.pencilKitWidth(for: kind, width: 2.5)
        #expect((1.5 ... 1.85).contains(fine), "\(kind) default \(fine)")
        let finest = PencilKitConversion.pencilKitWidth(for: kind, width: 1.5)
        #expect(finest <= range.lowerBound * 1.1, "\(kind) finest \(finest)")
        let boldest = PencilKitConversion.pencilKitWidth(for: kind, width: 8)
        #expect(boldest >= 3 * fine, "\(kind) boldest \(boldest)")
    }
}
