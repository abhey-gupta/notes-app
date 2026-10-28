import CoreGraphics

/// Tag for ``ImageID``.
public enum ImageTag {}
/// Tag for ``ImageAssetID``.
public enum ImageAssetTag {}

/// Identifies a ``PageImage`` (one placement on one page).
public typealias ImageID = TypedID<ImageTag>
/// Identifies image bytes in the notebook package (`images/<id>.heic`); several placements may share one.
public typealias ImageAssetID = TypedID<ImageAssetTag>

/// A photo placed on a page (#157): which bytes and where. Images sit beneath every stroke. Geometry
/// changes only through ``transformed(by:)`` (a new value, same ID).
public struct PageImage: Hashable, Sendable, Codable, Identifiable {
    /// Stable identity (UUIDv7).
    public let id: ImageID
    /// The bytes, by asset.
    public let asset: ImageAssetID
    /// Where it draws, page space (pt). Width/height keep the asset's aspect ratio; renderers stretch.
    public private(set) var frame: CGRect

    /// Creates a placement.
    public init(id: ImageID = ImageID(), asset: ImageAssetID, frame: CGRect) {
        self.id = id
        self.asset = asset
        self.frame = frame
    }

    /// Conservative page-space bounds (the frame; the rect to invalidate).
    public var bounds: CGRect {
        frame
    }

    /// Returns a copy (same ID) with `transform` applied to the frame. Translation and scale are exact;
    /// a rotation yields the rotated frame's bounding box (images don't rotate on Day 0).
    public func transformed(by transform: CGAffineTransform) -> PageImage {
        var copy = self
        copy.frame = frame.applying(transform)
        return copy
    }
}

/// An image at a z-order position in ``Page/images`` (0 = bottom).
public struct PlacedImage: Hashable, Sendable, Codable {
    /// Position in the page's image array.
    public var index: Int
    /// The image.
    public var image: PageImage

    /// Creates a placed image.
    public init(index: Int, image: PageImage) {
        self.index = index
        self.image = image
    }
}
