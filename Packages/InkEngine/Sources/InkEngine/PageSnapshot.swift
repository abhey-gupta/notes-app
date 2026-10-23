import CoreGraphics
import InkModel

/// Immutable view of one page for the engine: template, strokes in z-order, revision and size.
public struct PageSnapshot: Hashable, Sendable, Identifiable {
    /// The page value (strokes, template, rev).
    public let page: Page
    /// Page size in points (notebook page size).
    public let size: CGSize

    /// Creates a snapshot.
    public init(page: Page, size: CGSize) {
        self.page = page
        self.size = size
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

    /// Snapshot with `edit` applied (what an engine does on ``InkEngine/apply(_:to:)``).
    public func applying(_ edit: PageEdit) throws(PageEditError) -> PageSnapshot {
        try PageSnapshot(page: page.applying(edit), size: size)
    }
}
