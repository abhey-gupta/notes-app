import CoreGraphics
import Foundation
import InkModel
import UIKit

/// The ink engine seam (ARCHITECTURE.md §3.1): a UIKit view that draws and captures ink for the pages
/// it is told about, plus a small command surface. Implemented by `InkEnginePencilKit` (shipping,
/// spike #16) and `InkEngineMetal` (shelved, not wired into the app).
///
/// The canvas host (§5) owns scrolling, zooming and page layout. The engine never mutates the
/// document: it reports committed strokes and eraser/lasso input to its ``delegate``; `Tools` turns
/// them into ``InkModel/PageEdit``s, `DocumentStore` applies them and calls back ``apply(_:to:)``.
@MainActor
public protocol InkEngine: AnyObject {
    /// The engine's view: content-sized (unzoomed points), inside the host's zoom view, so the host's one
    /// zoom transform scales paper and ink together. It must draw only what the viewport shows.
    var view: UIView { get }
    /// Receives committed ink and tool input.
    var delegate: (any InkEngineDelegate)? { get set }

    /// Content offset, zoom and frames of the visible pages.
    func setViewport(_ viewport: Viewport)
    /// Immutable stroke snapshots for the visible pages (others may be dropped).
    func setPages(_ pages: [PageSnapshot])
    /// A loaded page is about to be handed over in ``setPages(_:)``: do what that would cost on main (e.g.
    /// converting strokes) off main now, so it doesn't stall a frame. Engines with nothing to do return.
    func prepare(_ page: PageSnapshot) async
    /// Current tool, color, width and finger-drawing setting.
    func setTool(_ tool: ToolConfiguration)
    /// Paper theme; ink colors resolve against it at render time.
    func setTheme(_ theme: PaperTheme)
    /// Replaces the color source (e.g. the notebook's "Keep exact colors" changed) and redraws.
    func setPalette(_ palette: any InkPalette)
    /// Color of the live lasso path.
    var selectionColor: UIColor { get set }
    /// `thumbs/<page>.heic` for a page: what an engine that draws ink asynchronously shows while a page's
    /// strokes load or its first raster renders. `nil`: flat paper meanwhile. Engines that draw at once ignore it.
    var thumbnailURL: ((PageID) -> URL?)? { get set }
    /// `images/<asset>.heic` for an image placed on a page (#157); `nil`: the image can't be shown.
    var imageURL: ((ImageAssetID) -> URL?)? { get set }
    /// Applies an edit the document already accepted (commit echo, undo/redo, lasso, erase).
    func apply(_ edit: PageEdit, to page: PageID)
    /// Lasso drag preview: lifts the strokes and draws them transformed; `nil` puts them back (call it
    /// after the baked edit has been applied, so they reappear where they landed). Called every drag frame.
    func setSelectionPreview(_ preview: SelectionPreview?)
    /// A selection was made: get its drag preview ready (off main) so a drag starts without a stall.
    /// An empty set drops it.
    func prepareSelectionPreview(_ strokes: Set<StrokeID>, on page: PageID)
    /// Renders a page (background + ink) at `size` points × `scale` for thumbnails and raster export.
    /// `nil` only if the size is degenerate or the bitmap can't be allocated.
    func render(page: PageSnapshot, size: CGSize, scale: CGFloat) async -> CGImage?
}

/// Receives engine output. All callbacks arrive on the main actor.
@MainActor
public protocol InkEngineDelegate: AnyObject {
    /// A pen stroke finished on `page`. Not yet part of the document; echo it back with ``InkEngine/apply(_:to:)``.
    func engine(_ engine: any InkEngine, didCommit stroke: Stroke, to page: PageID)
    /// Eraser input in page space, delivered incrementally (one batch per touch event). A new gesture
    /// starts at the preceding ``engineDidBeginStroke(_:)``. `Tools` resolves what gets erased.
    func engine(_ engine: any InkEngine, didReceiveEraser samples: [Sample], to page: PageID)
    /// A finished lasso path in page space.
    func engine(_ engine: any InkEngine, didReceiveLasso path: [CGPoint], to page: PageID)
    /// A pen, eraser or lasso gesture began (focus-mode chrome collapse; new eraser gesture).
    func engineDidBeginStroke(_ engine: any InkEngine)
    /// `page` shows its ink sharp (final raster or vectors drawn); fires on every such event. The app's
    /// `canvas.firstSharpTile` signpost ends on the first one after an open.
    func engine(_ engine: any InkEngine, didShowSharpInkOn page: PageID)
}
