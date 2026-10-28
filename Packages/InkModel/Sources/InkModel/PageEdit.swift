import CoreGraphics

/// A stroke at a z-order position in ``Page/strokes`` (0 = bottom).
public struct PlacedStroke: Hashable, Sendable, Codable {
    /// Position in the page's stroke array.
    public var index: Int
    /// The stroke.
    public var stroke: Stroke

    /// Creates a placed stroke.
    public init(index: Int, stroke: Stroke) {
        self.index = index
        self.stroke = stroke
    }
}

/// One stroke's color change, carrying the prior color so it can be undone.
public struct ColorChange: Hashable, Sendable, Codable {
    /// Stroke to recolor.
    public var id: StrokeID
    /// Color before the edit.
    public var from: InkColor
    /// Color after the edit.
    public var to: InkColor

    /// Creates a color change.
    public init(id: StrokeID, from: InkColor, to: InkColor) {
        self.id = id
        self.from = from
        self.to = to
    }
}

/// The single edit vocabulary for tools, undo/redo, the autosave journal and (later) sync.
///
/// Every edit is self-contained: it carries whatever prior state its undo needs (removed strokes and
/// their z-positions, prior colors, the inverse matrix), so ``inverse()`` is a pure function and
/// `edit.inverse().inverse() == edit`. Build edits with the factories on ``Page`` (``Page/addEdit(_:)``,
/// ``Page/removeEdit(_:)``, ``Page/replaceEdit(_:)``, ``Page/transformEdit(_:by:)``,
/// ``Page/recolorEdit(_:to:)``), which capture that state; apply with ``Page/apply(_:)``.
///
/// Index lists are strictly ascending. Inserts land at their index in the resulting array; removals
/// refer to indices in the current array.
public enum PageEdit: Hashable, Sendable, Codable {
    /// Inserts strokes at the given z-positions.
    case add([PlacedStroke])
    /// Removes the strokes at the given z-positions (IDs must match).
    case remove([PlacedStroke])
    /// Removes `old`, then inserts `new` (partial erase: pieces take the original's z-position).
    case replace(old: [PlacedStroke], new: [PlacedStroke])
    /// Bakes `forward` into the strokes' samples; `backward` is its inverse, used by ``inverse()``.
    /// Undo is exact up to Float rounding of sample coordinates.
    case transform([StrokeID], forward: CGAffineTransform, backward: CGAffineTransform)
    /// Changes stroke colors.
    case recolor([ColorChange])
    /// Inserts images at the given z-positions (#157).
    case addImages([PlacedImage])
    /// Removes the images at the given z-positions (IDs must match).
    case removeImages([PlacedImage])
    /// Bakes `forward` into the images' frames; `backward` is its inverse, used by ``inverse()``.
    case transformImages([ImageID], forward: CGAffineTransform, backward: CGAffineTransform)

    /// The edit that undoes this one when applied to the page this one produced.
    public func inverse() -> PageEdit {
        switch self {
        case let .add(placed): .remove(placed)
        case let .remove(placed): .add(placed)
        case let .replace(old, new): .replace(old: new, new: old)
        case let .transform(ids, forward, backward): .transform(ids, forward: backward, backward: forward)
        case let .recolor(changes): .recolor(changes.map { ColorChange(id: $0.id, from: $0.to, to: $0.from) })
        case let .addImages(placed): .removeImages(placed)
        case let .removeImages(placed): .addImages(placed)
        case let .transformImages(ids, forward, backward): .transformImages(ids, forward: backward, backward: forward)
        }
    }

    /// IDs of every stroke the edit touches (before and after). Empty for image edits.
    public var strokeIDs: [StrokeID] {
        switch self {
        case let .add(placed), let .remove(placed): placed.map(\.stroke.id)
        case let .replace(old, new): (old + new).map(\.stroke.id)
        case let .transform(ids, _, _): ids
        case let .recolor(changes): changes.map(\.id)
        case .addImages, .removeImages, .transformImages: []
        }
    }

    /// IDs of every image the edit touches. Empty for stroke edits.
    public var imageIDs: [ImageID] {
        switch self {
        case .add, .remove, .replace, .transform, .recolor: []
        case let .addImages(placed), let .removeImages(placed): placed.map(\.image.id)
        case let .transformImages(ids, _, _): ids
        }
    }

    /// The edit changes images only (strokes, and anything drawn from them, are untouched).
    public var touchesImagesOnly: Bool {
        switch self {
        case .add, .remove, .replace, .transform, .recolor: false
        case .addImages, .removeImages, .transformImages: true
        }
    }
}

/// Why a ``PageEdit`` could not be built or applied. Failed applies leave the page unchanged.
public enum PageEditError: Error, Hashable, Sendable {
    /// No stroke with this ID on the page.
    case unknownStroke(StrokeID)
    /// The ID is already on the page, or repeated within the edit.
    case duplicateStroke(StrokeID)
    /// Index outside the stroke array.
    case indexOutOfRange(Int)
    /// The stroke at `index` is not the one the edit expects.
    case indexMismatch(index: Int, expected: StrokeID)
    /// Placed-stroke (or placed-image) indices are not strictly ascending.
    case unsortedIndices
    /// No image with this ID on the page.
    case unknownImage(ImageID)
    /// The image ID is already on the page, or repeated within the edit.
    case duplicateImage(ImageID)
    /// The image at `index` is not the one the edit expects.
    case imageIndexMismatch(index: Int, expected: ImageID)
    /// The transform has a zero or non-finite determinant.
    case nonInvertibleTransform
}
