import CoreGraphics
import InkModel

/// Lasso drag/resize preview (ARCHITECTURE.md §6): the engine lifts `strokes` off `page` and draws them
/// with `transform` (page space) applied, cheaply enough for every frame of a drag, until the session
/// bakes the result as a `PageEdit.transform` and clears the preview.
public struct SelectionPreview: Hashable, Sendable {
    /// Page the strokes are on.
    public var page: PageID
    /// Strokes drawn transformed (and hidden in place).
    public var strokes: Set<StrokeID>
    /// Page-space transform applied to them.
    public var transform: CGAffineTransform

    /// Creates a preview.
    public init(page: PageID, strokes: Set<StrokeID>, transform: CGAffineTransform = .identity) {
        self.page = page
        self.strokes = strokes
        self.transform = transform
    }
}

public extension InkEngine {
    /// Engines without a preview path show the strokes in place until the baked edit arrives.
    func setSelectionPreview(_: SelectionPreview?) {}
}
