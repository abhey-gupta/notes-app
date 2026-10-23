import CoreGraphics
import InkModel

/// LRU of tiles by bytes (ARCHITECTURE.md §5.4). Pure bookkeeping, generic over the payload so the
/// policy tests run without a GPU; ``TiledContentRenderer`` stores textures.
///
/// A **stale** tile shows content that was invalidated since it was rendered. It keeps being drawn
/// (better than nothing) until its re-render lands.
struct TileCache<Value> {
    struct Entry {
        var value: Value
        var bytes: Int
        var lastUse: UInt64
        var isStale: Bool
    }

    private(set) var entries: [TileKey: Entry] = [:]
    /// Bytes of all entries.
    private(set) var bytes = 0
    private var clock: UInt64 = 0

    var count: Int {
        entries.count
    }

    subscript(key: TileKey) -> Entry? {
        entries[key]
    }

    /// Inserts or replaces `key` as most recently used. Returns the replaced value.
    @discardableResult
    mutating func insert(_ key: TileKey, _ value: Value, bytes: Int, isStale: Bool = false) -> Value? {
        clock += 1
        let old = entries.updateValue(Entry(value: value, bytes: bytes, lastUse: clock, isStale: isStale), forKey: key)
        self.bytes += bytes - (old?.bytes ?? 0)
        return old?.value
    }

    /// Marks `key` most recently used.
    mutating func touch(_ key: TileKey) {
        guard entries[key] != nil else { return }
        clock += 1
        entries[key]?.lastUse = clock
    }

    @discardableResult
    mutating func remove(_ key: TileKey) -> Value? {
        guard let old = entries.removeValue(forKey: key) else { return nil }
        bytes -= old.bytes
        return old.value
    }

    mutating func setStale(_ key: TileKey, _ stale: Bool) {
        entries[key]?.isStale = stale
    }

    /// Evicts least recently used entries not in `protected` until ``bytes`` ≤ `budget` (or only
    /// protected entries remain). Returns the evicted values.
    mutating func evict(toFit budget: Int, protecting protected: Set<TileKey>) -> [Value] {
        guard bytes > budget else { return [] }
        let candidates = entries.filter { !protected.contains($0.key) }.sorted { $0.value.lastUse < $1.value.lastUse }
        var evicted: [Value] = []
        for (key, _) in candidates {
            guard bytes > budget else { break }
            if let value = remove(key) {
                evicted.append(value)
            }
        }
        return evicted
    }

    /// Content of `page` changed in `rect` (`nil`: everywhere). Intersecting tiles at `keep` turn stale
    /// (they're redrawn until re-rendered); intersecting tiles at other buckets are evicted, so a
    /// fallback never shows outdated ink. Returns the stale keys and evicted values.
    mutating func invalidate(
        page: PageID,
        rect: CGRect?,
        keep bucket: ZoomBucket?,
        grid: TileGrid
    ) -> (stale: [TileKey], evicted: [Value]) {
        var stale: [TileKey] = []
        var evicted: [Value] = []
        for key in entries.keys where key.page == page {
            if let rect, !grid.rect(of: key).intersects(rect) {
                continue
            }
            if key.bucket == bucket {
                entries[key]?.isStale = true
                stale.append(key)
            } else if let value = remove(key) {
                evicted.append(value)
            }
        }
        return (stale, evicted)
    }

    /// Removes every entry not satisfying `keep`. Returns the removed values.
    mutating func removeAll(except keep: (TileKey) -> Bool) -> [Value] {
        var removed: [Value] = []
        for key in entries.keys where !keep(key) {
            if let value = remove(key) {
                removed.append(value)
            }
        }
        return removed
    }
}
