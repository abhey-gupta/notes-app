#if canImport(UIKit)
    @testable import Canvas
    import CoreGraphics
    import InkEngine
    import InkEngineTestSupport
    import InkModel
    import Testing
    import UIKit

    @MainActor
    final class WindowRecorder: CanvasHostViewDelegate {
        var windows: [PageWindow] = []

        func canvasHost(_: CanvasHostView, didChange window: PageWindow) {
            windows.append(window)
        }

        func canvasHostWillBeginNavigating(_: CanvasHostView) {}
        func canvasHostDidRequestNewPage(_: CanvasHostView) {}
        func canvasHostDidLiftAllTouches(_: CanvasHostView) {}
    }

    /// The canvas host and page residency through the engine seam, with a recording engine.
    @MainActor
    @Suite(.timeLimit(.minutes(1)))
    struct CanvasHostViewTests {
        let engine = RecordingInkEngine()
        let host: CanvasHostView
        let recorder = WindowRecorder()
        let ids = (0 ..< 10).map { _ in PageID() }

        init() {
            host = CanvasHostView(engine: engine)
            host.delegate = recorder
            host.layout = PageLayout(pageIDs: ids, footer: CanvasHostView.footerHeight)
            host.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
            host.layoutIfNeeded()
        }

        /// First layout: the engine hears about the top pages, the delegate gets the matching window.
        @Test func firstLayoutShowsTheTopPages() throws {
            let viewport = try #require(engine.viewports.last)
            #expect(viewport.pages.first?.id == ids[0])
            #expect(viewport.size == host.bounds.size)
            let window = try #require(recorder.windows.last)
            #expect(window.visible.lowerBound == 0)
            #expect(viewport.pages.map(\.id) == window.visible.map { ids[$0] })
        }

        @Test func scrollingMovesTheViewportAndWindow() throws {
            host.scrollToPage(6, animated: false)
            let viewport = try #require(engine.viewports.last)
            #expect(viewport.pages.contains { $0.id == ids[6] })
            #expect(!viewport.pages.contains { $0.id == ids[0] })
            #expect(try #require(recorder.windows.last).visible.contains(6))
        }

        /// The engine's view sits inside the zoomed content: content-sized, in page points.
        @Test func engineViewIsContentSized() {
            #expect(engine.view.bounds.size == host.layout.contentSize)
        }

        /// A pinch ending near fit width animates there as part of the zoom, then settles the engine once (#130).
        @Test func snapToFitWidthAnimatesThenSettles() async throws {
            let window = UIWindow(frame: host.frame)
            window.addSubview(host)
            window.isHidden = false
            let fit = host.fitWidthZoom
            host.canvasScrollView.zoomScale = fit * 0.94
            host.snapToFitWidth()
            #expect(host.isZooming)
            for _ in 0 ..< 400 where host.zoomSnapTarget != nil {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(host.zoomSnapTarget == nil)
            #expect(abs(host.canvasScrollView.zoomScale - fit) < 0.0001)
            let viewport = try #require(engine.viewports.last)
            #expect(!viewport.isZooming)
            #expect(abs(viewport.zoomScale - fit) < 0.0001)
        }

        /// Residency on iOS feeds the engine: page snapshots for the engine window, accepted edits as edits.
        @Test func residencyFeedsTheEngine() async throws {
            let h = try ResidencyHarness()
            let residency = PageResidency(
                store: h.store,
                engine: engine,
                pageSize: Notebook.a4Portrait,
                pages: h.ids.map { ($0, PageTemplate.blank) }
            )
            residency.update(PageWindow(visible: 0 ..< 1, pageCount: h.ids.count))
            #expect(engine.pages.map(\.id) == [h.ids[0], h.ids[1]])
            try await h.until { engine.pages.allSatisfy(\.isLoaded) }

            let edit = try await residency.ensureLoaded(h.ids[0]).addEdit([dot(y: 50)])
            _ = try await h.store.apply(edit, to: h.ids[0])
            residency.didApply(edit, to: h.ids[0])
            #expect(engine.applied.map(\.page) == [h.ids[0]])
        }
    }
#endif
