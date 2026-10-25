import InkEngine
import InkModel

/// Page images (#70) and the thumbnail-first open (#43): a page shows `thumbs/<id>.heic` scaled up until
/// its strokes load and its first raster renders, then crossfades; the first sharp page after an open
/// ends `canvas.firstSharpTile`.
extension NotebookSession {
    func installPageImages(on engine: any InkEngine) {
        engine.thumbnailURL = { [weak self] id in self?.thumbnails?.thumbnailURL(for: id) }
    }

    /// The engine showed sharp ink on `id` (raster landed or canvas drew): the first visible one after an
    /// open ends `canvas.firstSharpTile` (#43).
    func engine(_: any InkEngine, didShowSharpInkOn id: PageID) {
        guard awaitingFirstSharp, residency?.isVisible(id) == true else { return }
        awaitingFirstSharp = false
        FrameAfter.next { OpenTrace.sharp() }
    }
}
