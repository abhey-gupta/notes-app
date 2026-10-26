import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing

/// Pressure sensitivity off (#123): strokes commit at neutral force and one point size.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct PressureFlatteningTests {
    nonisolated static let kinds: [PenKind] = [.ballpoint, .fountain, .brush, .highlighter]

    /// A captured stroke whose pressure rises along it (as PencilKit reports it).
    static func captured(_ kind: PenKind) -> Stroke {
        let pk = PencilKitConversion.pkStroke(from: RenderFixtures.wave(1, origin: .zero, tool: kind), color: .black)
        return PencilKitConversion.stroke(from: pk, tool: kind, color: .primary, width: 4)
    }

    @Test(arguments: kinds)
    func flattenedStrokeHasOneWidthAtNeutralForce(kind: PenKind) throws {
        let stroke = Self.captured(kind)
        let flat = stroke.pressureFlattened
        let points = try #require(flat.rendering?.points)
        let original = try #require(stroke.rendering?.points.map(\.width))
        #expect(flat.id == stroke.id)
        #expect(flat.samples.count == stroke.samples.count)
        #expect(flat.samples.allSatisfy { $0.force == Sample.neutralForce })
        #expect(Set(points.map(\.width)).count == 1)
        #expect(Set(points.map(\.height)).count == 1)
        #expect(Set(points.map(\.secondaryScale)).count == 1)
        let width = try #require(points.first?.width)
        #expect(width >= (original.min() ?? 0) && width <= (original.max() ?? 0), "neutral lies within the pressure range")
        #expect(zip(flat.samples, stroke.samples).allSatisfy { $0.x == $1.x && $0.y == $1.y && $0.altitude == $1.altitude })
    }

    @Test func constantForceKeepsTheMedianSize() throws {
        let stroke = RenderFixtures.line(1, from: .zero, to: CGPoint(x: 100, y: 0), width: 4)
        let pk = PencilKitConversion.pkStroke(from: stroke, color: .black)
        let captured = PencilKitConversion.stroke(from: pk, tool: .ballpoint, color: .primary, width: 4)
        let sizes = try #require(captured.rendering?.points.map(\.width))
        let flat = try #require(captured.pressureFlattened.rendering?.points.map(\.width))
        #expect(flat.allSatisfy { $0 == sizes.sorted()[sizes.count / 2] })
    }

    @Test func emptyStrokeIsUnchanged() {
        let stroke = Stroke(tool: .ballpoint, color: .primary, width: 2, samples: [])
        #expect(stroke.pressureFlattened == stroke)
    }

    @Test(arguments: kinds)
    func pressureOffCommitsAndShowsFlattenedStroke(kind: PenKind) throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(kind), width: 4, pressure: false))
        h.userDraws(RenderFixtures.wave(1, origin: CGPoint(x: 10, y: 100), tool: kind), on: 2)
        let (stroke, _) = try #require(h.recorder.commits.first)
        #expect(stroke.samples.allSatisfy { $0.force == Sample.neutralForce })
        #expect(Set(stroke.rendering?.points.map(\.width) ?? []).count == 1)
        let shown = try #require(h.canvas(2)?.view.drawing.strokes.last)
        #expect(Set(shown.path.map(\.size.width)).count == 1, "the canvas swaps in the flattened stroke")
        #expect(h.canvas(2)?.ids == [stroke.id])
    }

    @Test func pressureOnCommitsStrokeAsDrawn() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setTool(ToolConfiguration(tool: .pen(.fountain), width: 4))
        let rebuilds = h.engine.rebuildCount
        h.userDraws(RenderFixtures.wave(1, origin: CGPoint(x: 10, y: 100)), on: 2)
        let (stroke, _) = try #require(h.recorder.commits.first)
        #expect(Set(stroke.samples.map(\.force)).count > 1)
        #expect(Set(stroke.rendering?.points.map(\.width) ?? []).count > 1)
        #expect(h.engine.rebuildCount == rebuilds)
    }
}
