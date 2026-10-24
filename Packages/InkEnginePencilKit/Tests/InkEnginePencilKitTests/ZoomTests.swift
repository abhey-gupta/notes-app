import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

/// Canvas placement during a pinch: ink stays on the paper every frame (real-iPad report: ink lagged the
/// page mid-pinch and snapped back at the end).
@MainActor
struct ZoomTests {
    // MARK: Math

    @Test(arguments: [0.5, 1, 1.37, 2, 4] as [CGFloat])
    func scaledPlacementPutsPagePointsWhereThePaperIs(zoom: CGFloat) {
        let region = CGRect(x: 40, y: 120, width: 400, height: 500) // page space, rendered at 1.3
        let pageOrigin = CGPoint(x: -213.5, y: 77.25)
        let placement = CanvasPlacement.scaled(
            region: region, renderZoom: 1.3, pageOrigin: pageOrigin, zoom: zoom, pageSize: RenderFixtures.pageSize
        )
        #expect(placement.renderZoom == 1.3)
        #expect(abs(placement.scale - zoom / 1.3) < 1e-12)
        #expect(placement.contentSize == CGSize(width: 595 * 1.3, height: 842 * 1.3))
        for p in [CGPoint(x: 40, y: 120), CGPoint(x: 440, y: 620), CGPoint(x: 123.4, y: 456.7), CGPoint(x: 0, y: 0)] {
            let view = placement.viewPoint(p)
            #expect(abs(view.x - (pageOrigin.x + zoom * p.x)) < 1e-9)
            #expect(abs(view.y - (pageOrigin.y + zoom * p.y)) < 1e-9)
        }
        // The canvas covers exactly the region, wherever the zoom is.
        let frame = placement.frame
        #expect(abs(frame.minX - (pageOrigin.x + region.minX * zoom)) < 1e-9)
        #expect(abs(frame.maxY - (pageOrigin.y + region.maxY * zoom)) < 1e-9)
        #expect(placement.region.equalTo(region) || abs(placement.region.maxX - region.maxX) < 1e-9)
    }

    @Test func settledPlacementIsTheVisibleRect() {
        let pageRect = CGRect(x: 100, y: -300, width: 595 * 1.5, height: 842 * 1.5)
        let visible = pageRect.intersection(CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let placement = CanvasPlacement.settled(visible: visible, pageRect: pageRect, zoom: 1.5, pageSize: RenderFixtures.pageSize)
        #expect(placement.scale == 1)
        #expect(placement.frame == visible)
        #expect(placement.bounds.origin == CGPoint(x: 0, y: 300))
        let scaled = CanvasPlacement.scaled(
            region: placement.region, renderZoom: 1.5, pageOrigin: pageRect.origin, zoom: 1.5, pageSize: RenderFixtures.pageSize
        )
        #expect(scaled == placement)
    }

    // MARK: Engine

    @Test func pinchHoldsCanvasZoomAndScalesItThenSettles() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        let page = h.frames[1]
        let bounds = h.engine.canvas.bounds
        let rebuilds = h.engine.rebuildCount

        for zoom in [1.1, 1.4, 0.8, 0.6] as [CGFloat] {
            let viewport = h.viewport(offset: CGPoint(x: 0, y: 900 * zoom), zoom: zoom, isZooming: true)
            h.engine.setViewport(viewport)
            #expect(h.engine.canvas.zoomScale == 1, "PencilKit keeps its rendering mid-pinch")
            #expect(h.engine.canvas.bounds == bounds)
            #expect(h.engine.canvas.transform == CGAffineTransform(scaleX: zoom, y: zoom))
            // Canvas content lands on the paper: page point → view, through the canvas's own geometry.
            let pageRect = viewport.viewRect(of: page)
            for p in [CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 500)] {
                let content = CGPoint(x: p.x * h.engine.canvas.zoomScale, y: p.y * h.engine.canvas.zoomScale)
                let view = h.engine.canvas.convert(content, to: h.engine.view)
                #expect(abs(view.x - (pageRect.minX + p.x * zoom)) < 1e-6)
                #expect(abs(view.y - (pageRect.minY + p.y * zoom)) < 1e-6)
            }
            // Zoomed out, the page raster shows around what the canvas covers.
            let view = h.engine.pageViews[page.id]
            #expect(view?.showsInk == true)
            #expect(view?.inkHole == CGRect(x: 0, y: 34, width: 595, height: 808))
        }
        #expect(h.engine.rebuildCount == rebuilds)

        // Pinch ends: the canvas takes the final zoom once, untransformed; the raster stays until it has drawn.
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 540), zoom: 0.6, isZooming: false))
        #expect(h.engine.canvas.zoomScale == 0.6)
        #expect(h.engine.canvas.transform == .identity)
        let visible = h.engine.viewport.viewRect(of: page).intersection(h.engine.view.bounds)
        let frame = h.engine.canvas.frame
        #expect([frame.minX - visible.minX, frame.minY - visible.minY, frame.width - visible.width, frame.height - visible.height]
            .allSatisfy { abs($0) < 1e-9 })
        #expect(h.engine.pageViews[page.id]?.showsInk == true)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        #expect(h.engine.pageViews[page.id]?.showsInk == false)
        #expect(h.engine.pageViews[page.id]?.inkHole == nil)
        #expect(h.engine.zoom.freeze == nil)
    }

    /// The host keeps `isZooming` through the scroll a release starts (deceleration, rubber band): the canvas
    /// stays held and follows the paper by geometry, and only settles once the page is at rest.
    @Test func releaseScrollKeepsTheCanvasHeldUntilRest() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        let page = h.frames[1]
        let bounds = h.engine.canvas.bounds
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 900 * 1.3), zoom: 1.3, isZooming: true))
        #expect(h.engine.canvas.zoomScale == 1)

        // Fingers up; the page decelerates for a few frames at the final zoom.
        for y in stride(from: 1170, through: 1290, by: 40) as StrideThrough<CGFloat> {
            let viewport = h.viewport(offset: CGPoint(x: 0, y: y), zoom: 1.3, isZooming: true)
            h.engine.setViewport(viewport)
            #expect(h.engine.canvas.zoomScale == 1, "held: nothing for PencilKit to re-render mid-scroll")
            #expect(h.engine.canvas.bounds == bounds)
            #expect(h.engine.canvas.transform == CGAffineTransform(scaleX: 1.3, y: 1.3))
            let pageRect = viewport.viewRect(of: page)
            for p in [CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 500)] {
                let view = h.engine.canvas.convert(CGPoint(x: p.x, y: p.y), to: h.engine.view)
                #expect(abs(view.x - (pageRect.minX + p.x * 1.3)) < 1e-6)
                #expect(abs(view.y - (pageRect.minY + p.y * 1.3)) < 1e-6)
            }
        }

        // At rest: settle once, untransformed, where the paper is.
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 1290), zoom: 1.3, isZooming: false))
        #expect(h.engine.canvas.zoomScale == 1.3)
        #expect(h.engine.canvas.transform == .identity)
        let visible = h.engine.viewport.viewRect(of: page).intersection(h.engine.view.bounds)
        let frame = h.engine.canvas.frame
        #expect([frame.minX - visible.minX, frame.minY - visible.minY, frame.width - visible.width, frame.height - visible.height]
            .allSatisfy { abs($0) < 1e-9 })
    }

    /// Lasso-lifted strokes follow the pinch with the paper and stay out of the raster shown around the canvas.
    @Test func liftedSelectionFollowsThePinch() throws {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.canvasViewDidFinishRendering(h.engine.canvas)
        let page = h.frames[1]
        let move = CGAffineTransform(translationX: 20, y: 10)
        h.engine.setSelectionPreview(SelectionPreview(page: page.id, strokes: [RenderFixtures.strokeID(9)], transform: move))
        let rect = h.engine.selection.rect
        for zoom in [1.2, 0.7] as [CGFloat] {
            let viewport = h.viewport(offset: CGPoint(x: 0, y: 900 * zoom), zoom: zoom, isZooming: true)
            h.engine.setViewport(viewport)
            let expected = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .concatenating(move).concatenating(viewport.pageToView(page))
            let actual = h.engine.selection.lifted.affineTransform()
            #expect([actual.a - expected.a, actual.d - expected.d, actual.tx - expected.tx, actual.ty - expected.ty]
                .allSatisfy { abs($0) < 1e-9 })
            let key = try #require(h.engine.pageViews[page.id]?.requestedKey)
            #expect(key.strokeCount == 0, "lifted stroke not in the active page's raster")
        }
    }

    @Test func canvasNotYetDrawnKeepsTheWholeRasterMidPinch() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 990), zoom: 1.1, isZooming: true))
        let view = h.engine.pageViews[h.frames[1].id]
        #expect(view?.showsInk == true)
        #expect(view?.inkHole == nil)
        #expect(h.engine.canvas.zoomScale == 1)
    }

    /// Pixels: render the engine view's layer tree (what Core Animation commits for the frame) mid-pinch
    /// and check the canvas's ink and the raster's ink sit where the paper says.
    @Test func inkStaysOnThePaperEveryPinchFrame() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let engine = PencilKitInkEngine(palette: FixturePalette())
        controller.view.addSubview(engine.view)
        engine.view.frame = controller.view.bounds
        let id = RenderFixtures.pageID(1)
        // A: on screen when the pinch starts (the canvas draws it). B: far down the page, revealed by
        // zooming out (the raster draws it).
        let a = RenderFixtures.line(1, from: CGPoint(x: 100, y: 200), to: CGPoint(x: 500, y: 200), width: 4)
        let b = RenderFixtures.line(2, from: CGPoint(x: 100, y: 780), to: CGPoint(x: 500, y: 780), width: 4)
        engine.setPages([PageSnapshot(page: Page(id: id, template: .blank, strokes: [a, b]), size: RenderFixtures.pageSize)])
        let pages = [VisiblePage(id: id, frame: CGRect(origin: .zero, size: RenderFixtures.pageSize))]
        var offset = CGPoint(x: 0, y: 0)
        var zoom: CGFloat = 2
        func send(zooming: Bool) {
            engine.setViewport(Viewport(
                contentOffset: offset,
                zoomScale: zoom,
                size: engine.view.bounds.size,
                pages: pages,
                isZooming: zooming
            ))
            window.layoutIfNeeded()
        }
        send(zooming: false)
        // The canvas has drawn A (not just timed out waiting for `canvasViewDidFinishRendering`).
        try await waitUntil { engine.canvasHasRendered && Self.inkY(Self.render(engine.view), x: 600, near: 400) != nil }

        // Pinch out about view point (300, 700), as UIScrollView does: zoom and offset change together.
        let anchor = CGPoint(x: 300, y: 700)
        for step in 1 ... 8 {
            let content = CGPoint(x: (offset.x + anchor.x) / zoom, y: (offset.y + anchor.y) / zoom)
            zoom = 2 - CGFloat(step) * 0.15
            offset = CGPoint(x: content.x * zoom - anchor.x, y: content.y * zoom - anchor.y)
            send(zooming: true)
            #expect(engine.canvas.zoomScale == 2)
            let pixels = Self.render(engine.view)
            let x = 300 * zoom - offset.x
            #expect(Self.inkY(pixels, x: x, near: 200 * zoom - offset.y).map { abs($0) < 1.5 } == true, "A, zoom \(zoom)")
        }
        // B comes from the raster, once it has rendered.
        try await waitUntil { engine.pageViews[id]?.shownKey != nil }
        let pixels = Self.render(engine.view)
        let x = 300 * zoom - offset.x
        #expect(Self.inkY(pixels, x: x, near: 780 * zoom - offset.y).map { abs($0) < 1.5 } == true, "B")
        #expect(Self.inkY(pixels, x: x, near: 200 * zoom - offset.y).map { abs($0) < 1.5 } == true, "A")

        // Settle: same places at the final zoom.
        send(zooming: false)
        #expect(engine.canvas.zoomScale == zoom)
        let settled = Self.render(engine.view)
        #expect(Self.inkY(settled, x: x, near: 200 * zoom - offset.y).map { abs($0) < 1.5 } == true, "A settled")
        #expect(Self.inkY(settled, x: x, near: 780 * zoom - offset.y).map { abs($0) < 1.5 } == true, "B settled")
    }

    private static func render(_ view: UIView) -> (RGBAPixels, scale: CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
        return (RGBAPixels(image.cgImage!), 2) // swiftlint:disable:this force_unwrapping
    }

    /// Offset (pt) of the dark ink's center in column `x` from `expected`, looking within ±12 pt.
    private static func inkY(
        _ rendered: (RGBAPixels, scale: CGFloat), x: CGFloat, near expected: CGFloat, within: CGFloat = 12
    ) -> CGFloat? {
        let (pixels, scale) = rendered
        let column = Int(x * scale)
        let rows = Int((expected - within) * scale) ... Int((expected + within) * scale)
        let dark = rows.filter { y in
            guard y >= 0, y < pixels.bytes.count / 4 / pixels.width else { return false }
            let p = pixels[column, y]
            return p.a > 200 && p.r < 128
        }
        guard !dark.isEmpty else { return nil }
        return CGFloat(dark.reduce(0, +)) / CGFloat(dark.count) / scale - expected
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

extension Harness {
    func viewport(offset: CGPoint, zoom: CGFloat, isZooming: Bool) -> Viewport {
        Viewport(contentOffset: offset, zoomScale: zoom, size: engine.view.bounds.size, pages: frames, isZooming: isZooming)
    }
}
