import InkModel

/// The notebooks open as editor tabs (#191): their order in the bar, which one is showing, and how
/// recently each was active, so the oldest cold tab gives way when the limit is reached.
///
/// Pure value; the app persists it between launches and drops ids whose notebooks no longer exist
/// (``prune(keeping:)``).
public struct OpenTabs: Hashable, Codable, Sendable {
    /// Most tabs open at once.
    public static let limit = 6

    /// Tabs in bar order.
    public private(set) var ids: [NotebookID]
    /// The tab showing; `nil` only when there are no tabs.
    public private(set) var active: NotebookID?
    /// Tabs from most to least recently active.
    private var recency: [NotebookID]

    public init() {
        ids = []
        active = nil
        recency = []
    }

    public var isEmpty: Bool {
        ids.isEmpty
    }

    public var count: Int {
        ids.count
    }

    public func contains(_ id: NotebookID) -> Bool {
        ids.contains(id)
    }

    /// Shows `id`: a new tab at the end, or the existing one. Over ``limit`` the least recently active other
    /// tab closes first; its id comes back so the caller can close its session.
    @discardableResult
    public mutating func open(_ id: NotebookID) -> NotebookID? {
        var evicted: NotebookID?
        if !ids.contains(id) {
            if ids.count >= Self.limit, let oldest = recency.last(where: { $0 != id }) {
                remove(oldest)
                evicted = oldest
            }
            ids.append(id)
        }
        activate(id)
        return evicted
    }

    /// Shows an open tab.
    public mutating func activate(_ id: NotebookID) {
        guard ids.contains(id) else { return }
        active = id
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    /// Closes `id`. Closing the showing tab shows its right-hand neighbour, or the left one at the end.
    public mutating func close(_ id: NotebookID) {
        guard let index = ids.firstIndex(of: id) else { return }
        let wasActive = active == id
        remove(id)
        if wasActive, !ids.isEmpty {
            activate(ids[min(index, ids.count - 1)])
        }
    }

    /// Closes every tab but `id` (which becomes the showing one).
    public mutating func closeOthers(keeping id: NotebookID) {
        guard ids.contains(id) else { return }
        ids = [id]
        recency = [id]
        active = id
    }

    /// Drops tabs whose notebooks are gone. Returns the ids dropped.
    @discardableResult
    public mutating func prune(keeping existing: Set<NotebookID>) -> [NotebookID] {
        let gone = ids.filter { !existing.contains($0) }
        for id in gone {
            close(id)
        }
        return gone
    }

    /// The tab after the showing one, wrapping around (⌃Tab).
    public var next: NotebookID? {
        neighbour(offset: 1)
    }

    /// The tab before the showing one, wrapping around (⌃⇧Tab).
    public var previous: NotebookID? {
        neighbour(offset: -1)
    }

    private func neighbour(offset: Int) -> NotebookID? {
        guard let active, let index = ids.firstIndex(of: active), ids.count > 1 else { return nil }
        return ids[(index + offset + ids.count) % ids.count]
    }

    private mutating func remove(_ id: NotebookID) {
        ids.removeAll { $0 == id }
        recency.removeAll { $0 == id }
        if active == id {
            active = nil
        }
    }
}
