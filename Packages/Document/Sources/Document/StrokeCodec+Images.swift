import CoreGraphics
import Foundation
import InkModel

/// What a stroke file holds: a page's strokes and its images (#157).
public struct PageContent: Hashable, Sendable {
    /// Strokes, bottom to top.
    public var strokes: [Stroke]
    /// Images beneath the strokes, bottom to top.
    public var images: [PageImage]

    /// Creates page content.
    public init(strokes: [Stroke] = [], images: [PageImage] = []) {
        self.strokes = strokes
        self.images = images
    }

    /// The content of `page`.
    public init(_ page: Page) {
        strokes = page.strokes
        images = page.images
    }
}

extension StrokeCodec {
    /// Reads one image placement (v3). Caller guarantees ``imageLength`` bytes remain. Shared with the
    /// journal codec.
    static func readImage(_ reader: inout ByteReader) -> PageImage {
        let id = ImageID(uuid: UUID(uuid: reader.read(uuid_t.self)))
        let asset = ImageAssetID(uuid: UUID(uuid: reader.read(uuid_t.self)))
        func f() -> CGFloat {
            CGFloat(Double(bitPattern: UInt64(littleEndian: reader.read(UInt64.self))))
        }
        let frame = CGRect(x: f(), y: f(), width: f(), height: f())
        return PageImage(id: id, asset: asset, frame: frame)
    }
}

extension ByteWriter {
    mutating func append(_ id: ImageID) {
        withUnsafeBytes(of: id.uuid.uuid) { bytes.append(contentsOf: $0) }
    }

    /// u128 id | u128 asset | f64 x, y, w, h (``StrokeCodec/imageLength`` bytes).
    mutating func append(_ image: PageImage) {
        append(image.id)
        withUnsafeBytes(of: image.asset.uuid.uuid) { bytes.append(contentsOf: $0) }
        for v in [image.frame.origin.x, image.frame.origin.y, image.frame.width, image.frame.height] {
            append(Double(v).bitPattern)
        }
    }
}
