import CoreGraphics
import InkEngine
@testable import InkEnginePencilKit
import InkEngineTestSupport
import InkModel
import PencilKit
import Testing
import UIKit

/// Zoom (ARCHITECTURE.md §3): the engine view sits in the host's zoom view, so paper and ink share one
/// transform; canvases are left alone during a pinch and re-tiled once at the end, in place.
@Suite(.timeLimit(.minutes(5)))
@MainActor
struct ZoomTests {
    // MARK: Math

    @Test(arguments: [0.5, 1, 1.37, 2, 4] as [CGFloat])
    func placementCoversTheVisiblePartOfThePageInPlace(zoom: CGFloat) throws {
        let pageFrame = CGRect(x: 0, y: 866, width: 595, height: 842)
        let visible = CGRect(x: -40, y: 900, width: 700, height: 500)
        let placement = try #require(CanvasPlacement.visible(pageFrame: pageFrame, in: visible, zoom: zoom))
        #expect(placement.zoom == zoom)
        #expect(placement.region == CGRect(x: 0, y: 34, width: 595, height: 500))
        #expect(abs(placement.scale - 1 / zoom) < 1e-12)
        #expect(placement.contentSize == CGSize(width: 595 * zoom, height: 842 * zoom))
        #expect(placement.bounds.origin == CGPoint(x: 0, y: 34 * zoom), "contentOffset shows the region")
        // Page points land where the paper puts them, whatever the zoom: content = page origin + point.
        for p in [CGPoint(x: 0, y: 34), CGPoint(x: 300, y: 250), CGPoint(x: 595, y: 500), CGPoint(x: 123.4, y: 456.7)] {
            let content = placement.contentPoint(p)
            #expect(abs(content.x - p.x) < 1e-9)
            #expect(abs(content.y - (866 + p.y)) < 1e-9)
        }
        let frame = placement.frame
        #expect(abs(frame.minY - 900) < 1e-9 && abs(frame.maxY - 1400) < 1e-9 && abs(frame.width - 595) < 1e-9)
    }

    @Test func noPlacementOffscreen() {
        let pageFrame = CGRect(x: 0, y: 866, width: 595, height: 842)
        #expect(CanvasPlacement.visible(pageFrame: pageFrame, in: CGRect(x: 0, y: 0, width: 600, height: 800), zoom: 1) == nil)
        #expect(CanvasPlacement.visible(pageFrame: pageFrame, in: CGRect(x: 0, y: 1708, width: 600, height: 800), zoom: 1) == nil)
        #expect(CanvasPlacement.visible(pageFrame: pageFrame, in: CGRect(x: 0, y: 900, width: 600, height: 800), zoom: 0) == nil)
    }

    // MARK: Engine

    @Test func pinchLeavesCanvasesAloneThenRetilesThemInPlace() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1]
        let canvas = try #require(h.engine.canvas(for: page.id))
        h.engine.canvasViewDidFinishRendering(canvas.view)
        let before = (canvas.view.bounds, canvas.view.center, canvas.view.transform, canvas.view.zoomScale)
        let view = try #require(h.engine.pageViews[page.id])
        #expect(view.inkHole == CGRect(x: 0, y: 34, width: 595, height: 808))
        let rebuilds = h.engine.rebuildCount

        for zoom in [1.1, 1.4, 0.8, 0.6] as [CGFloat] {
            h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 900 * zoom), zoom: zoom, isZooming: true))
            #expect(canvas.view.zoomScale == before.3, "nothing for PencilKit to re-tile mid-pinch")
            #expect(canvas.view.bounds == before.0)
            #expect(canvas.view.center == before.1)
            #expect(canvas.view.transform == before.2)
            #expect(view.frame == page.frame, "paper is in content space: the zoom is the host's transform")
            #expect(view.inkHole == CGRect(x: 0, y: 34, width: 595, height: 808), "raster still shows around the canvas")
            #expect(h.engine.canvas(for: page.id) === canvas)
        }
        #expect(h.engine.rebuildCount == rebuilds)

        // Pinch ends: the canvas takes the final zoom once, scaled back so it covers the same page region.
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 540), zoom: 0.6, isZooming: false))
        #expect(canvas.view.zoomScale == 0.6)
        #expect(abs(canvas.view.transform.a - 1 / 0.6) < 1e-9)
        let placement = try #require(canvas.placement)
        #expect(placement.region == CGRect(x: 0, y: 34, width: 595, height: 808))
        // Canvas content lands on the paper: page point → content, through the canvas's own geometry.
        for p in [CGPoint(x: 50, y: 50), CGPoint(x: 300, y: 500)] {
            let content = CGPoint(x: p.x * 0.6, y: p.y * 0.6)
            let inHost = canvas.view.convert(content, to: h.engine.view)
            // Exact even though the scroll view pixel-aligned the offset (34 · 0.6 = 20.4 → 20.5 at 2×).
            #expect(abs(inHost.x - (page.frame.minX + p.x)) < 1e-6, "\(p): \(inHost)")
            #expect(abs(inHost.y - (page.frame.minY + p.y)) < 1e-6, "\(p): \(inHost)")
        }
        // The raster hole is what the canvas had drawn (the same region here; `inkStaysOnThePaperEveryPinchFrame`
        // covers a region that grew) until PencilKit has drawn the new placement.
        #expect(view.inkHole == CGRect(x: 0, y: 34, width: 595, height: 808))
        h.engine.canvasViewDidFinishRendering(canvas.view)
        #expect(view.inkHole == placement.region)
    }

    /// Lasso-lifted strokes sit in content space too, so they follow the pinch with the paper and stay out of
    /// the raster shown around the canvas.
    @Test func liftedSelectionFollowsThePinch() throws {
        let h = Harness()
        h.scroll(toY: 900)
        let page = h.frames[1]
        let move = CGAffineTransform(translationX: 20, y: 10)
        h.engine.setSelectionPreview(SelectionPreview(page: page.id, strokes: [RenderFixtures.strokeID(9)], transform: move))
        let rect = h.engine.selection.rect
        for zoom in [1.2, 0.7] as [CGFloat] {
            h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 900 * zoom), zoom: zoom, isZooming: true))
            let expected = CGAffineTransform(translationX: rect.minX, y: rect.minY)
                .concatenating(move).concatenating(CGAffineTransform(translationX: page.frame.minX, y: page.frame.minY))
            let actual = h.engine.selection.lifted.affineTransform()
            #expect([actual.a - expected.a, actual.d - expected.d, actual.tx - expected.tx, actual.ty - expected.ty]
                .allSatisfy { abs($0) < 1e-9 })
            let key = try #require(h.engine.pageViews[page.id]?.requestedKey)
            #expect(key.strokeCount == 0, "lifted stroke not in the page's raster")
        }
    }

    @Test func canvasNotYetDrawnKeepsTheWholeRasterMidPinch() {
        let h = Harness()
        h.scroll(toY: 900)
        h.engine.setViewport(h.viewport(offset: CGPoint(x: 0, y: 990), zoom: 1.1, isZooming: true))
        let view = h.engine.pageViews[h.frames[1].id]
        #expect(view?.inkHole == nil)
        #expect(h.engine.canvas(for: h.frames[1].id)?.view.zoomScale == 1)
    }

    /// Pixels: the engine view inside a zoom view like the host's, rendered (what Core Animation commits
    /// for the frame) on every pinch frame: the canvas's ink and the raster's ink sit where the paper says.
    /// The host: a bounds-offset "scroll view" holding a zoom view that the engine view fills.
    @MainActor
    private struct MiniHost {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        let scroll: UIView
        let zoomView: UIView
        let engine = PencilKitInkEngine(palette: FixturePalette())

        init() {
            let controller = UIViewController()
            window.rootViewController = controller
            window.makeKeyAndVisible()
            scroll = UIView(frame: controller.view.bounds)
            controller.view.addSubview(scroll)
            zoomView = UIView(frame: CGRect(origin: .zero, size: RenderFixtures.pageSize))
            zoomView.layer.anchorPoint = .zero
            zoomView.layer.position = .zero
            scroll.addSubview(zoomView)
            engine.view.frame = zoomView.bounds
            zoomView.addSubview(engine.view)
        }
    }

    @Test func inkStaysOnThePaperEveryPinchFrame() async throws {
        let host = MiniHost()
        let (window, scroll, zoomView, engine) = (host.window, host.scroll, host.zoomView, host.engine)
        defer { window.isHidden = true }
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
            zoomView.transform = CGAffineTransform(scaleX: zoom, y: zoom)
            scroll.bounds.origin = offset
            engine.setViewport(Viewport(contentOffset: offset, zoomScale: zoom, size: scroll.bounds.size, pages: pages, isZooming: zooming))
            window.layoutIfNeeded()
        }
        send(zooming: false)
        let canvas = try #require(engine.canvas(for: id))
        // The canvas has drawn A (not just timed out waiting for `canvasViewDidFinishRendering`).
        try await waitUntil { canvas.hasRendered && Self.inkY(Self.render(scroll), x: 600, near: 400) != nil }

        // Pinch out about view point (300, 700), as UIScrollView does: zoom and offset change together.
        let anchor = CGPoint(x: 300, y: 700)
        for step in 1 ... 8 {
            let content = CGPoint(x: (offset.x + anchor.x) / zoom, y: (offset.y + anchor.y) / zoom)
            zoom = 2 - CGFloat(step) * 0.15
            offset = CGPoint(x: content.x * zoom - anchor.x, y: content.y * zoom - anchor.y)
            send(zooming: true)
            #expect(canvas.view.zoomScale == 2)
            let pixels = Self.render(scroll)
            let x = 300 * zoom - offset.x
            let measured = Self.inkY(pixels, x: x, near: 200 * zoom - offset.y, within: 200)
            #expect(measured.map { abs($0) < 1.5 } == true, "A, zoom \(zoom): off by \(String(describing: measured))")
        }
        // B comes from the raster, once it has rendered.
        try await waitUntil { engine.pageViews[id]?.shownKey != nil }
        let pixels = Self.render(scroll)
        let x = 300 * zoom - offset.x
        #expect(Self.inkY(pixels, x: x, near: 780 * zoom - offset.y).map { abs($0) < 1.5 } == true, "B")
        #expect(Self.inkY(pixels, x: x, near: 200 * zoom - offset.y).map { abs($0) < 1.5 } == true, "A")

        // Settle: same places at the final zoom.
        send(zooming: false)
        #expect(canvas.view.zoomScale == zoom)
        let settled = Self.render(scroll)
        #expect(Self.inkY(settled, x: x, near: 200 * zoom - offset.y).map { abs($0) < 1.5 } == true, "A settled")
        #expect(Self.inkY(settled, x: x, near: 780 * zoom - offset.y).map { abs($0) < 1.5 } == true, "B settled")
    }

    private static func render(_ view: UIView) -> (RGBAPixels, scale: CGFloat) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            // `render(in:)` ignores the layer's bounds origin (the scroll offset); apply it like the screen does.
            context.cgContext.translateBy(x: -view.bounds.minX, y: -view.bounds.minY)
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
        Viewport(contentOffset: offset, zoomScale: zoom, size: viewSize, pages: frames, isZooming: isZooming)
    }
}
