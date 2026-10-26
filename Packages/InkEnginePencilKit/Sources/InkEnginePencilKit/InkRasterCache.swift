import CoreGraphics
import Foundation
import InkModel

/// The page-image cache (#70, ARCHITECTURE.md §3): ink rasters of recently shown pages per zoom bucket,
/// plus decoded page thumbnails, LRU by bytes.
///
/// A raster is keyed by its page, the content it shows (``PageLayerView/InkKey/content``) and its pixel
/// scale. Inserting a raster drops the page's rasters of *other* content (an edit invalidates them; the
/// newest one stays as a stand-in until then) and keeps its other buckets, so a zoom finds the nearest
/// one (``nearest(for:content:pixelScale:)``) while the right bucket renders. Thumbnails share the budget.
@MainActor
final class InkRasterCache {
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
        /// `nil`: the page's thumbnail.
        var content: PageLayerView.ContentKey?
        var pixelScale: CGFloat
    }

    private struct Entry {
        var image: CGImage
        var bytes: Int
        var insertedAt: Int
    }

    private var clock = 0

    /// 1/32 of physical memory, at most 128 MB (≈ 4 full-page rasters at 2× zoom on a 2× screen).
    static var defaultBudget: Int {
        Int(min(ProcessInfo.processInfo.physicalMemory / 32, 128 << 20))
    }

    init(budget: Int = InkRasterCache.defaultBudget) {
        self.budget = budget
    }

    var count: Int {
        entries.count
    }

    var isEmpty: Bool {
        entries.isEmpty
    }

    // MARK: Rasters

    /// The raster for `page` rendered for exactly `key`; marks it recently used.
    func image(for page: PageID, key: PageLayerView.InkKey) -> CGImage? {
        let k = Key(page: page, content: key.content, pixelScale: key.pixelScale)
        guard let entry = entries[k] else { return nil }
        touch(k)
        return entry.image
    }

    /// The same content at the bucket nearest `pixelScale` (a zoom's stand-in: scaled, slightly soft).
    func nearest(for page: PageID, content: PageLayerView.ContentKey, pixelScale: CGFloat) -> CGImage? {
        let candidates = entries.keys.filter { $0.page == page && $0.content == content }
        // Ties go to the lower bucket (cheaper, and deterministic: `entries` has no order).
        func distance(_ k: Key) -> (CGFloat, CGFloat) {
            (abs(log2(k.pixelScale / pixelScale)), k.pixelScale)
        }
        guard let k = candidates.min(by: { distance($0) < distance($1) }) else {
            return nil
        }
        touch(k)
        return entries[k]?.image
    }

    /// Whatever raster `page` has at `size` (any content, newest first): a stand-in while the current one
    /// renders. A raster of another page size (before widening, #129) would show stretched.
    func latestImage(for page: PageID, size: CGSize) -> CGImage? {
        entries.filter { $0.key.page == page && $0.key.content?.size == size }.max { $0.value.insertedAt < $1.value.insertedAt }?.value
            .image
    }

    /// Inserts a raster; rasters of the page's other content are dropped (invalidated by the edit).
    func insert(_ image: CGImage, for page: PageID, key: PageLayerView.InkKey) {
        for k in entries.keys where k.page == page && k.content != nil && k.content != key.content {
            remove(k)
        }
        put(image, at: Key(page: page, content: key.content, pixelScale: key.pixelScale))
    }

    // MARK: Thumbnails

    /// The decoded `thumbs/<page>.heic`, if cached.
    func thumbnail(for page: PageID) -> CGImage? {
        let k = Key(page: page, content: nil, pixelScale: 0)
        guard let entry = entries[k] else { return nil }
        touch(k)
        return entry.image
    }

    func insertThumbnail(_ image: CGImage, for page: PageID) {
        put(image, at: Key(page: page, content: nil, pixelScale: 0))
    }

    // MARK: Removal

    /// Drops every image of `page`.
    func remove(_ page: PageID) {
        for k in entries.keys where k.page == page {
            remove(k)
        }
    }

    /// Drops every thumbnail (the paper changed).
    func removeThumbnails() {
        for k in entries.keys where k.content == nil {
            remove(k)
        }
    }

    func removeAll() {
        entries = [:]
        order = []
        bytes = 0
    }

    // MARK: Private

    private func put(_ image: CGImage, at key: Key) {
        remove(key)
        let size = image.bytesPerRow * image.height
        clock += 1
        entries[key] = Entry(image: image, bytes: size, insertedAt: clock)
        order.append(key)
        bytes += size
        trim()
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
