import InkModel

/// The notebooks open as editor tabs (#191): their order in the bar, which one is showing, and how
/// recently each was active, so the oldest cold tab gives way when the limit is reached.
///
/// Split view (#175): a second pane can show another tab (or the same notebook again) beside the first.
/// ``active`` is the primary pane's tab, ``secondary`` the other pane's; ``focus`` is the pane last
/// touched, which opening, switching and closing from the keyboard or the library act on. Closing a tab
/// that a pane shows closes that pane; the other one stays.
///
/// Pure value; the app persists it between launches and drops ids whose notebooks no longer exist
/// (``prune(keeping:)``).
public struct OpenTabs: Hashable, Codable, Sendable {
    /// One side of the split.
    public enum Pane: String, Hashable, Codable, Sendable {
        case primary, secondary

        public var other: Pane {
            self == .primary ? .secondary : .primary
        }
    }

    /// Most tabs open at once.
    public static let limit = 6

    /// Tabs in bar order.
    public private(set) var ids: [NotebookID]
    /// The tab showing; `nil` only when there are no tabs.
    public private(set) var active: NotebookID?
    /// The second pane's tab in split view; `nil` without a split. May equal ``active``: one notebook, two
    /// places in it.
    public private(set) var secondary: NotebookID?
    /// The pane last touched.
    public private(set) var focus = Pane.primary
    /// Where the divider rests: the primary pane's share of the editor.
    public var splitFraction = SplitGeometry.half
    /// Tabs from most to least recently active.
    private var recency: [NotebookID]

    public init() {
        ids = []
        active = nil
        recency = []
    }

    public var isSplit: Bool {
        secondary != nil
    }

    /// The tab `pane` shows.
    public func showing(_ pane: Pane) -> NotebookID? {
        switch pane {
        case .primary: active
        case .secondary: secondary
        }
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

    /// Shows `id` in the focused pane: a new tab at the end, or the existing one. Over ``limit`` the least
    /// recently active tab no pane shows closes first; its id comes back so the caller can close its session.
    @discardableResult
    public mutating func open(_ id: NotebookID) -> NotebookID? {
        let evicted = add(id)
        activate(id)
        return evicted
    }

    /// Shows an open tab in the focused pane.
    public mutating func activate(_ id: NotebookID) {
        show(id, in: focus)
    }

    /// Shows an open tab in `pane` (the secondary pane only in split view) and focuses that pane.
    public mutating func show(_ id: NotebookID, in pane: Pane) {
        guard ids.contains(id), pane == .primary || isSplit else { return }
        switch pane {
        case .primary: active = id
        case .secondary: secondary = id
        }
        focus = pane
        touch(id)
    }

    /// Splits the editor: `id` (a new tab if need be, or the one already showing) opens in the secondary
    /// pane, which takes focus. Without a showing tab it just opens. Returns the tab evicted, if any.
    @discardableResult
    public mutating func openSplit(_ id: NotebookID) -> NotebookID? {
        guard active != nil else { return open(id) }
        let evicted = add(id)
        secondary = id
        focus = .secondary
        touch(id)
        return evicted
    }

    /// Ends the split; `pane`'s tab is the one left showing.
    public mutating func closeSplit(keeping pane: Pane) {
        guard let secondary else { return }
        if pane == .secondary {
            active = secondary
        }
        self.secondary = nil
        focus = .primary
    }

    /// The panes trade tabs; focus follows its tab.
    public mutating func swapPanes() {
        guard let secondary, let active else { return }
        self.active = secondary
        self.secondary = active
        focus = focus.other
    }

    /// `pane` was touched.
    public mutating func focus(_ pane: Pane) {
        guard pane == .primary || isSplit else { return }
        focus = pane
    }

    /// Closes `id`. A pane showing it closes; without a split the next tab shows: the right-hand neighbour,
    /// or the left one at the end.
    public mutating func close(_ id: NotebookID) {
        guard let index = ids.firstIndex(of: id) else { return }
        remove(id)
        switch (active == id, secondary == id) {
        case (false, true):
            closeSplit(keeping: .primary)
        case (true, false):
            if isSplit {
                closeSplit(keeping: .secondary)
            } else {
                active = nil
                if !ids.isEmpty {
                    activate(ids[min(index, ids.count - 1)])
                }
            }
        case (true, true):
            secondary = nil
            active = nil
            focus = .primary
            if !ids.isEmpty {
                activate(ids[min(index, ids.count - 1)])
            }
        case (false, false):
            break
        }
    }

    /// Closes every tab but `id` (which becomes the only one showing).
    public mutating func closeOthers(keeping id: NotebookID) {
        guard ids.contains(id) else { return }
        ids = [id]
        recency = [id]
        active = id
        secondary = nil
        focus = .primary
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

    /// The tab after the focused pane's, wrapping around (⌃Tab).
    public var next: NotebookID? {
        neighbour(offset: 1)
    }

    /// The tab before the focused pane's, wrapping around (⌃⇧Tab).
    public var previous: NotebookID? {
        neighbour(offset: -1)
    }

    private func neighbour(offset: Int) -> NotebookID? {
        guard let current = showing(focus), let index = ids.firstIndex(of: current), ids.count > 1 else { return nil }
        return ids[(index + offset + ids.count) % ids.count]
    }

    /// Adds `id` at the end unless it's open; past ``limit`` the coldest tab no pane shows makes room.
    private mutating func add(_ id: NotebookID) -> NotebookID? {
        guard !ids.contains(id) else { return nil }
        var evicted: NotebookID?
        if ids.count >= Self.limit, let oldest = recency.last(where: { $0 != id && $0 != active && $0 != secondary }) {
            remove(oldest)
            evicted = oldest
        }
        ids.append(id)
        return evicted
    }

    private mutating func touch(_ id: NotebookID) {
        recency.removeAll { $0 == id }
        recency.insert(id, at: 0)
    }

    private mutating func remove(_ id: NotebookID) {
        ids.removeAll { $0 == id }
        recency.removeAll { $0 == id }
    }
}
