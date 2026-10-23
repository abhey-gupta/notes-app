import CoreGraphics
import Foundation
import InkModel

/// Tile resolutions (ARCHITECTURE.md §5.4): a bucket-`b` tile holds `b × screen scale` pixels per page
/// point, so zoom `b` shows it 1:1.
enum ZoomBucket: Int8, CaseIterable, Comparable, Sendable {
    case half = -1, one = 0, two = 1, four = 2

    /// Page magnification the bucket is rendered at.
    var scale: CGFloat {
        CGFloat(pow(2, Double(rawValue)))
    }

    /// Zoom above a bucket's scale that it still serves (softness of a 10 % magnification is invisible;
    /// rounding every zoom up would hold 4× the pixels just past each bucket).
    static let magnificationTolerance: CGFloat = 1.1

    /// The sharpest bucket needed at `zoom`: the smallest whose scale × tolerance reaches it.
    static func forZoom(_ zoom: CGFloat) -> ZoomBucket {
        allCases.first { $0.scale * magnificationTolerance >= zoom } ?? .four
    }

    /// The other buckets, nearest first (sharper first on ties): the fallback order for a missing tile.
    var fallbacks: [ZoomBucket] {
        Self.allCases.filter { $0 != self }.sorted {
            let a = abs(Int($0.rawValue) - Int(rawValue))
            let b = abs(Int($1.rawValue) - Int(rawValue))
            return a == b ? $0 > $1 : a < b
        }
    }

    static func < (lhs: ZoomBucket, rhs: ZoomBucket) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One cached tile: a `tilePixels`² square of `page` at `bucket`, `col`/`row` from the page's top-left.
struct TileKey: Hashable, Sendable, CustomStringConvertible {
    var page: PageID
    var bucket: ZoomBucket
    var col: Int32
    var row: Int32

    var description: String {
        "\(bucket.scale)x[\(col),\(row)]"
    }
}

/// Tile ↔ page-space math for one screen scale.
struct TileGrid: Equatable, Sendable {
    /// Tile edge in pixels (square, BGRA8: 1 MiB per tile).
    static let tilePixels = 512

    /// Device pixels per view point (the drawable's scale).
    var pixelsPerPoint: CGFloat

    /// Tile edge in page points at `bucket`.
    func side(_ bucket: ZoomBucket) -> CGFloat {
        CGFloat(Self.tilePixels) / (bucket.scale * pixelsPerPoint)
    }

    /// Page-space rect covered by `key` (may overhang the page's right/bottom edge).
    func rect(of key: TileKey) -> CGRect {
        let s = side(key.bucket)
        return CGRect(x: CGFloat(key.col) * s, y: CGFloat(key.row) * s, width: s, height: s)
    }

    /// Columns × rows covering a page of `size` at `bucket`.
    func dimensions(_ size: CGSize, _ bucket: ZoomBucket) -> (cols: Int, rows: Int) {
        let s = side(bucket)
        return (max(Int((size.width / s).rounded(.up)), 1), max(Int((size.height / s).rounded(.up)), 1))
    }

    /// Tiles of `page` (of `size`) at `bucket` overlapping `rect` (page space), row-major.
    func keys(_ page: PageID, _ bucket: ZoomBucket, covering rect: CGRect, pageSize size: CGSize) -> [TileKey] {
        let clipped = rect.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return [] }
        let s = side(bucket)
        let (cols, rows) = dimensions(size, bucket)
        let c0 = max(Int((clipped.minX / s).rounded(.down)), 0)
        let r0 = max(Int((clipped.minY / s).rounded(.down)), 0)
        let c1 = min(Int((clipped.maxX / s).rounded(.up)) - 1, cols - 1)
        let r1 = min(Int((clipped.maxY / s).rounded(.up)) - 1, rows - 1)
        guard c1 >= c0, r1 >= r0 else { return [] }
        var keys: [TileKey] = []
        keys.reserveCapacity((c1 - c0 + 1) * (r1 - r0 + 1))
        for row in r0 ... r1 {
            for col in c0 ... c1 {
                keys.append(TileKey(page: page, bucket: bucket, col: Int32(col), row: Int32(row)))
            }
        }
        return keys
    }
}

/// Tile cache budget (ARCHITECTURE.md §5.4): 256 MiB on an 8 GB iPad, scaled with physical memory.
///
/// Clamped to 96...320 MiB: the floor keeps one zoomed-in screen plus neighbours resident on small
/// devices; the ceiling keeps the app under the 400 MB resident target of #22 on 12/16 GB iPads (the
/// budget caps LRU retention of off-screen buckets, it isn't what a scroll needs: visible ± prefetch at
/// one bucket is ~100 MiB on a 13" screen).
enum TileBudget {
    static let base = 256 << 20
    static let range = (96 << 20) ... (320 << 20)

    static func bytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let scaled = Double(base) * Double(physicalMemory) / Double(UInt64(8) << 30)
        return min(max(Int(scaled), range.lowerBound), range.upperBound)
    }
}
