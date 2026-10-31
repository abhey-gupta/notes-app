import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import Testing
import UIKit

/// Ghost ink (#225): a replaced version of a page, dashed in the selection color under the ink; never on a
/// canvas, kept across scrolling, gone when cleared.
@Suite(.timeLimit(.minutes(2)))
@MainActor
struct GhostInkTests {
    @Test func ghostIsDashedBeneathTheInkAndLeavesTheCanvasAlone() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1].id
        let canvas = try #require(h.canvas(1))
        let ghost = [
            RenderFixtures.line(20, from: CGPoint(x: 60, y: 200), to: CGPoint(x: 300, y: 220)),
            RenderFixtures.line(21, from: CGPoint(x: 60, y: 260), to: CGPoint(x: 300, y: 280)),
        ]
        h.engine.setGhost(ghost, on: page)
        let view = try #require(h.engine.pageViews[page])
        let layers = view.ghostShapeLayers
        #expect(layers.count == 2)
        #expect(layers.allSatisfy { $0.lineDashPattern?.count == 2 && $0.fillColor == nil })
        let color = h.engine.selectionColor.withAlphaComponent(PencilKitInkEngine.ghostOpacity).cgColor
        #expect(layers.first?.strokeColor == color)
        #expect(canvas.ids == [RenderFixtures.strokeID(9)], "the canvas has only the page's own ink")
        let sublayers = view.layer.sublayers ?? []
        let ghostIndex = try #require(sublayers.firstIndex { $0 === view.ghostLayer })
        let inkIndex = try #require(sublayers.firstIndex { $0.sublayers?.contains { $0 === view.inkLayer } == true })
        #expect(ghostIndex < inkIndex, "under the ink image")
        #expect(!view.isUserInteractionEnabled)

        // Scrolled away and back: a new page view gets it again.
        h.scroll(toY: 2400)
        h.scroll(toY: 900)
        #expect(h.engine.pageViews[page]?.ghostShapeLayers.count == 2)

        h.engine.setGhost([], on: page)
        #expect(h.engine.ghosts[page] == nil)
        #expect(h.engine.pageViews[page]?.ghostIDs.isEmpty == true, "fades out")
        #expect(h.engine.pageViews[h.frames[0].id]?.ghostShapeLayers.isEmpty ?? true, "other pages never had one")
    }
}

extension PageLayerView {
    var ghostShapeLayers: [CAShapeLayer] {
        (ghostLayer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }
}
