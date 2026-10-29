import CoreGraphics
import Foundation
import InkModel

/// Whole-page bitmaps of imported artwork (PDF pages, #193) per zoom bucket, LRU by bytes, kept across
/// page visits: a page scrolled away and back shows its bitmap at once, no render. Artwork never
/// changes for a page, so an entry is only ever evicted, not invalidated. Separate from
/// ``InkRasterCache`` (its budget is sized for ink, and an edit must not evict a book's pages).
@MainActor
final class ArtworkRasterCache {
    /// Byte budget; least recently used entries beyond it are dropped.
    var budget: Int {
        didSet { trim() }
    }

    private(set) var bytes = 0
    private var entries: [Key: Entry] = [:]
    /// Least recently used first.
    private var order: [Key] = []

    private struct Key: Hashable {
        var page: PageID
        var key: ArtworkLayer.Key
    }

    private struct Entry {
        var image: CGImage
        var bytes: Int
    }

    /// 1/16 of physical memory, at most 192 MB (≈ 25 A4 pages at 1× zoom on a 2× screen, 6 at 2×).
    static var defaultBudget: Int {
        Int(min(ProcessInfo.processInfo.physicalMemory / 16, 192 << 20))
    }

    init(budget: Int = ArtworkRasterCache.defaultBudget) {
        self.budget = budget
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    /// The bitmap of `page` for exactly `key`; marks it recently used.
    func image(for page: PageID, key: ArtworkLayer.Key) -> CGImage? {
        let k = Key(page: page, key: key)
        guard let entry = entries[k] else { return nil }
        touch(k)
        return entry.image
    }

    /// The bitmap of `page` at the bucket nearest `key.pixelScale` (a zoom's stand-in: scaled by the
    /// layer), among those covering `key.size`.
    func nearest(for page: PageID, key: ArtworkLayer.Key) -> (image: CGImage, key: ArtworkLayer.Key)? {
        let candidates = entries.keys.filter { $0.page == page && $0.key.size == key.size }
        // Ties go to the higher bucket (sharper when minified).
        func distance(_ k: Key) -> (CGFloat, CGFloat) {
            (abs(log2(k.key.pixelScale / key.pixelScale)), -k.key.pixelScale)
        }
        guard let k = candidates.min(by: { distance($0) < distance($1) }), let entry = entries[k] else { return nil }
        touch(k)
        return (entry.image, k.key)
    }

    func insert(_ image: CGImage, for page: PageID, key: ArtworkLayer.Key) {
        let k = Key(page: page, key: key)
        remove(k)
        let size = image.bytesPerRow * image.height
        entries[k] = Entry(image: image, bytes: size)
        order.append(k)
        bytes += size
        trim()
    }

    func removeAll() {
        entries = [:]
        order = []
        bytes = 0
    }

    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        bytes -= entry.bytes
        order.removeAll { $0 == key }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func trim() {
        while bytes > budget, let oldest = order.first {
            remove(oldest)
        }
    }
}
