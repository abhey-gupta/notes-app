import Canvas
import CoreGraphics
import Document
import InkEngine
import InkModel
import os

/// Page images (#70) and the thumbnail-first open (#43): a page shows `thumbs/<id>.heic` scaled up until
/// its strokes load and its first raster renders, then crossfades; the first sharp page after an open
/// ends `canvas.firstSharpTile`.
extension NotebookSession {
    func installPageImages(on engine: any InkEngine) {
        engine.thumbnailURL = { [weak self] id in self?.thumbnails?.thumbnailURL(for: id) }
    }

    /// Imported PDF pages (#119), opened off main; the engine looks them up per page. Each sits on the
    /// original page of a widened one (#129).
    func installArtwork(from store: DocumentStore) async {
        let artwork = await store.artwork()
        guard !artwork.isEmpty, !isClosed else { return }
        artworkPlacement.pageExtension = await PageExtension(notebook: store.manifest.notebook)
        self.artwork = artwork.mapValues { [artworkPlacement] in PlacedArtwork(base: $0, placement: artworkPlacement) }
        engine.pageArtwork = { [weak self] id in self?.artwork[id] }
    }

    /// The engine showed sharp ink on `id` (raster landed or canvas drew): the first visible one after an
    /// open ends `canvas.firstSharpTile` (#43).
    func engine(_: any InkEngine, didShowSharpInkOn id: PageID) {
        pageShowedSharpInk(id)
        guard awaitingFirstSharp, residency?.isVisible(id) == true else { return }
        awaitingFirstSharp = false
        FrameAfter.next { OpenTrace.sharp() }
    }
}

/// The notebook's page extension (#129) as imported artwork sees it: pages widen while tiles draw off main.
final class ArtworkPlacement: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: PageExtension.none)

    var pageExtension: PageExtension {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// Imported artwork on the original page of a widened one: page space starts at the extension's left
/// edge (#129), so the artwork moves right by it and keeps the original width; the extra paper stays paper.
struct PlacedArtwork: PageArtwork {
    let base: any PageArtwork
    let placement: ArtworkPlacement

    func draw(in context: CGContext, size: CGSize) {
        let e = placement.pageExtension
        let width = size.width - e.left - e.right
        guard width > 0 else { return }
        context.saveGState()
        context.translateBy(x: e.left, y: 0)
        base.draw(in: context, size: CGSize(width: width, height: size.height))
        context.restoreGState()
    }
}
