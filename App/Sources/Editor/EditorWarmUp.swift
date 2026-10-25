import Canvas
import CoreGraphics
import InkEngine
import InkEnginePencilKit
import InkModel

/// Pays the canvas's first-use costs while the library sits idle, so the first notebook open of a launch
/// doesn't pay them as the zoom transition starts: cold, the canvas host's glass "Add page" button takes
/// ~45 ms to build and the first `PKCanvasView` ~20 ms.
@MainActor
enum EditorWarmUp {
    private static var done = false

    /// Builds and drops an off-screen canvas host showing one page with one stroke. Runs once.
    static func run() {
        guard !done else { return }
        done = true
        let engine = PencilKitInkEngine(palette: DesignSystemInkPalette())
        let host = CanvasHostView(engine: engine)
        let page = Page(strokes: [
            Stroke(tool: .ballpoint, color: .primary, width: 2, samples: [Sample(x: 40, y: 40, t: 0), Sample(x: 80, y: 44, t: 0.02)]),
        ])
        host.layout = PageLayout(pageIDs: [page.id], footer: CanvasHostView.footerHeight)
        host.frame = CGRect(x: 0, y: 0, width: 1024, height: 1366)
        host.layoutIfNeeded()
        engine.setPages([PageSnapshot(page: page, size: Notebook.a4Portrait)])
    }
}
