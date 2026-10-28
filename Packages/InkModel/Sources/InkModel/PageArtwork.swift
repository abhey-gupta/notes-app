import CoreGraphics

/// Imported artwork a page is drawn on (a PDF page, #119): over the paper, under template marks and ink.
/// Engines and export draw it from any thread; implementations synchronize their own state.
public protocol PageArtwork: Sendable {
    /// Draws into `context` in page space (origin top-left, y down), fitted to a page of `size` points.
    func draw(in context: CGContext, size: CGSize)
}
