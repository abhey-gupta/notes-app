import CoreGraphics
import Foundation
import InkModel

/// Ink rasters of recently shown inactive pages, LRU by bytes, so scrolling back to a page shows its ink
/// at once instead of re-rendering `PKDrawing.image`. A simple stand-in for the page-image cache (#70):
/// one raster per page (the latest key wins), no zoom-bucket fallbacks.
@MainActor
final class InkRasterCache {
    /// Byte budget; least recently used rasters beyond it are dropped.
    var budget: Int {
        didSet { trim() }
    }

    private(set) var bytes = 0
    private var entries: [PageID: Entry] = [:]
    /// Least recently used first.
    private var order: [PageID] = []

    private struct Entry {
        var key: PageLayerView.InkKey
        var image: CGImage
        var bytes: Int
    }

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

    /// The raster for `page` if it was rendered for `key`; marks it recently used.
    func image(for page: PageID, key: PageLayerView.InkKey) -> CGImage? {
        guard let entry = entries[page], entry.key == key else { return nil }
        touch(page)
        return entry.image
    }

    /// Whatever raster `page` has, current or not (a stand-in while the current one renders).
    func latestImage(for page: PageID) -> CGImage? {
        entries[page]?.image
    }

    func insert(_ image: CGImage, for page: PageID, key: PageLayerView.InkKey) {
        remove(page)
        let size = image.bytesPerRow * image.height
        entries[page] = Entry(key: key, image: image, bytes: size)
        order.append(page)
        bytes += size
        trim()
    }

    func remove(_ page: PageID) {
        guard let entry = entries.removeValue(forKey: page) else { return }
        bytes -= entry.bytes
        order.removeAll { $0 == page }
    }

    func removeAll() {
        entries = [:]
        order = []
        bytes = 0
    }

    private func touch(_ page: PageID) {
        order.removeAll { $0 == page }
        order.append(page)
    }

    private func trim() {
        while bytes > budget, let oldest = order.first {
            remove(oldest)
        }
    }
}
