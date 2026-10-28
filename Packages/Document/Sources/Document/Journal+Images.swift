import CoreGraphics
import Foundation
import InkModel

/// Journal records for image edits (#157, version 3): kinds 5 (`addImages`), 6 (`removeImages`) and
/// 7 (`transformImages`); see ``Journal`` for the layout.
extension Journal {
    /// Appends the kind byte and body of an image edit (`encodeRecord`).
    static func appendImageEdit(_ edit: PageEdit, to w: inout ByteWriter) {
        switch edit {
        case let .addImages(placed):
            w.append(UInt8(5))
            w.append(placed)
        case let .removeImages(placed):
            w.append(UInt8(6))
            w.append(placed)
        case let .transformImages(ids, forward, backward):
            w.append(UInt8(7))
            w.append(UInt32(ids.count))
            for id in ids {
                w.append(id)
            }
            w.append(forward)
            w.append(backward)
        case .add, .remove, .replace, .transform, .recolor:
            preconditionFailure("not an image edit")
        }
    }

    /// Reads the body of image-edit `kind` (5...7); `nil` if malformed.
    static func readImageEdit(kind: UInt8, _ r: inout ByteReader) -> PageEdit? {
        switch kind {
        case 5: readPlacedImages(&r).map(PageEdit.addImages)
        case 6: readPlacedImages(&r).map(PageEdit.removeImages)
        case 7: readTransformImagesEdit(&r)
        default: nil
        }
    }

    static func readPlacedImages(_ r: inout ByteReader) -> [PlacedImage]? {
        guard let n = readCount(&r, itemSize: 4 + StrokeCodec.imageLength) else { return nil }
        var placed: [PlacedImage] = []
        placed.reserveCapacity(n)
        for _ in 0 ..< n {
            guard r.remaining >= 4 + StrokeCodec.imageLength else { return nil }
            let index = Int(UInt32(littleEndian: r.read(UInt32.self)))
            placed.append(PlacedImage(index: index, image: StrokeCodec.readImage(&r)))
        }
        return placed
    }

    static func readTransformImagesEdit(_ r: inout ByteReader) -> PageEdit? {
        guard let n = readCount(&r, itemSize: 16) else { return nil }
        let ids = (0 ..< n).map { _ in ImageID(uuid: UUID(uuid: r.read(uuid_t.self))) }
        guard r.remaining >= 96 else { return nil }
        return .transformImages(ids, forward: readTransform(&r), backward: readTransform(&r))
    }
}

extension ByteWriter {
    mutating func append(_ placed: [PlacedImage]) {
        append(UInt32(placed.count))
        for p in placed {
            append(UInt32(clamping: p.index))
            append(p.image)
        }
    }
}
