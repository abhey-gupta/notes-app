import enum DesignSystem.Tokens
import InkEnginePencilKit
import InkModel

/// Page images (#70) and the thumbnail-first open (#43): a page shows `thumbs/<id>.heic` scaled up until
/// its strokes load and its first raster renders, then crossfades; the first sharp page after an open
/// ends `canvas.firstSharpTile`.
extension NotebookSession {
    func installPageImages(on engine: PencilKitInkEngine) {
        engine.crossfadeDuration = Tokens.Motion.thumbnailCrossfadeDuration
        engine.thumbnailURL = { [weak self] id in self?.thumbnails?.thumbnailURL(for: id) }
        engine.onPageSharp = { [weak self] id in self?.pageSharp(id) }
    }

    /// The engine showed sharp ink on `id` (raster landed or canvas drew): the first visible one after an
    /// open ends `canvas.firstSharpTile` (#43).
    private func pageSharp(_ id: PageID) {
        guard awaitingFirstSharp, residency?.isVisible(id) == true else { return }
        awaitingFirstSharp = false
        FrameAfter.next { OpenTrace.sharp() }
    }
}
