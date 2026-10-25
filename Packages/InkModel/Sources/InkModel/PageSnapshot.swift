import CoreGraphics

/// Immutable view of one page for an ink engine: template, strokes in z-order, revision and size.
public struct PageSnapshot: Hashable, Sendable, Identifiable {
    /// The page value (strokes, template, rev).
    public let page: Page
    /// Page size in points (notebook page size).
    public let size: CGSize
    /// `false` while the page's strokes are still loading (a placeholder with the template and no ink):
    /// an engine shows the page's thumbnail instead of treating it as blank (#43).
    public let isLoaded: Bool

    /// Creates a snapshot.
    public init(page: Page, size: CGSize, isLoaded: Bool = true) {
        self.page = page
        self.size = size
        self.isLoaded = isLoaded
    }

    /// Page identity.
    public var id: PageID {
        page.id
    }

    /// Strokes, bottom to top.
    public var strokes: [Stroke] {
        page.strokes
    }

    /// Page revision.
    public var rev: UInt64 {
        page.rev
    }

    /// Snapshot with `edit` applied (what an ink engine does when it applies an edit).
    public func applying(_ edit: PageEdit) throws(PageEditError) -> PageSnapshot {
        try PageSnapshot(page: page.applying(edit), size: size, isLoaded: isLoaded)
    }
}
