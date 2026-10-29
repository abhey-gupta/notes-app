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

        func canvasHostDidRequestNewPage(_: CanvasHostView) {}
        func canvasHostDidBeginTouch(_: CanvasHostView) {}
        func canvasHostDidLiftAllTouches(_: CanvasHostView) {}
    }

    final class Target {
        var undone = 0
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

        /// At fit width the page covers the view edge to edge: no side inset, offset at the page's left
        /// edge, and the engine sees a content rect exactly one page wide (#130).
        @Test func fitWidthCoversTheWholeView() throws {
            let fill = host.fillZoom
            #expect(fill == host.bounds.width / host.layout.pageSize.width)
            host.animateZoom(to: fill, duration: 0)
            let scroll = host.canvasScrollView
            #expect(scroll.zoomScale == fill)
            #expect(scroll.contentInset.left == 0)
            #expect(scroll.contentInset.right == 0)
            #expect(scroll.contentOffset.x == 0)
            #expect(scroll.contentSize.width == host.bounds.width)
            let viewport = try #require(engine.viewports.last)
            #expect(viewport.zoomScale == fill)
            #expect(viewport.contentOffset.x == 0)
            #expect(abs(viewport.size.width / viewport.zoomScale - host.layout.pageSize.width) < 0.001)
        }

        /// A saved position comes back: same page point under the chrome, same zoom; fitted stays fitted.
        @Test func readingPositionRoundTrips() throws {
            host.animateZoom(to: 2, duration: 0)
            host.scrollToPage(6, animated: false)
            host.canvasScrollView.contentOffset.x += 40
            let saved = try #require(host.readingPosition)
            #expect(saved.width == .zoomed)

            let other = CanvasHostView(engine: RecordingInkEngine())
            other.layout = host.layout
            other.restore(saved) // before the first layout: applied by it
            other.frame = host.frame
            other.layoutIfNeeded()
            #expect(other.canvasScrollView.zoomScale == 2)
            #expect(other.canvasScrollView.contentOffset == host.canvasScrollView.contentOffset)
            #expect(other.state.currentPage == host.state.currentPage)

            other.restore(ReadingPosition(origin: CGPoint(x: 0, y: 100_000), zoom: 1, width: .fitted))
            let scroll = other.canvasScrollView
            #expect(abs(scroll.zoomScale - CanvasHostView.fitZoom(pageWidth: other.layout.pageSize.width, viewWidth: 1024)) < 0.001)
            #expect(abs(scroll.contentOffset.y - (scroll.contentSize.height + scroll.contentInset.bottom - scroll.bounds.height)) < 0.5)
            #expect(other.readingPosition?.width == .fitted)
        }

        /// The engine's view sits inside the zoomed content: content-sized, in page points.
        @Test func engineViewIsContentSized() {
            #expect(engine.view.bounds.size == host.layout.contentSize)
        }

        /// A smaller top margin (toolbar off the top edge) snaps a viewport above it to the new top; a bigger
        /// one leaves the viewport where it is.
        @Test func topMarginChangeSnapsTheTopViewport() {
            let scroll = host.canvasScrollView
            #expect(scroll.contentOffset.y == -scroll.contentInset.top)
            host.margins.top = 14
            #expect(scroll.contentInset.top == 14)
            #expect(scroll.contentOffset.y == -14)
            host.margins.top = 72
            #expect(scroll.contentInset.top == 72)
            #expect(scroll.contentOffset.y == -14)
            host.scrollToPage(3, animated: false)
            let y = scroll.contentOffset.y
            host.margins.top = 14
            #expect(scroll.contentOffset.y == y)
        }

        /// Without the add-page button (automatic new pages, #172) the space below the last page is 5 % of a
        /// page, with no bottom margin; back with the button.
        @Test func noAddPageButtonLeavesFivePercentBelow() {
            let scroll = host.canvasScrollView
            #expect(scroll.contentInset.bottom > 0)
            host.showsAddPage = false
            host.layoutIfNeeded()
            #expect(host.layout.footer == (host.layout.pageSize.height * 0.05).rounded())
            #expect(host.layout.pageIDs == ids)
            #expect(scroll.contentInset.bottom == 0)
            host.showsAddPage = true
            host.layoutIfNeeded()
            #expect(host.layout.footer == CanvasHostView.footerHeight)
            #expect(scroll.contentInset.bottom > 0)
        }

        /// Two- and three-finger taps (#121) undo and redo through the delegate (the default goes to the
        /// host's undo manager); off with the setting and while fingers ink. While on, the system's
        /// three-finger editing gestures are off.
        @Test func fingerTapsUndoAndRedo() {
            let target = Target()
            let undo = host.editUndoManager
            undo.groupsByEvent = false
            func register() {
                undo.beginUndoGrouping()
                undo.registerUndo(withTarget: target) { $0.undone += 1 }
                undo.endUndoGrouping()
            }
            register()
            #expect(host.editingInteractionConfiguration == .none)
            host.fingersTapped(2)
            #expect(target.undone == 1)

            register()
            host.allowsTapUndo = false
            host.fingersTapped(2)
            #expect(target.undone == 1, "setting off")
            #expect(host.editingInteractionConfiguration == .default)

            host.allowsTapUndo = true
            host.allowsFingerDrawing = true
            host.fingersTapped(2)
            #expect(target.undone == 1, "one finger inks")
            host.allowsFingerDrawing = false
            host.fingersTapped(4)
            #expect(target.undone == 1, "four fingers: nothing")
            host.fingersTapped(2)
            #expect(target.undone == 2)
        }

        /// No tap recognizers on the scroll view: even a disabled one slowed its pan enough to swallow a
        /// fast flick (the fixture scroll UI test caught it).
        @Test func scrollViewHasNoTapRecognizers() {
            #expect(!(host.canvasScrollView.gestureRecognizers ?? []).contains { $0 is UITapGestureRecognizer })
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
