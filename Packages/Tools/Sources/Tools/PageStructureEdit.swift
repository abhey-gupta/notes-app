import InkModel

/// A change to the notebook's page order (pages overview, #32): insert, delete or move. Lives in the same
/// history as ink edits (``EditEntry/structure``) so undo walks pages and strokes in one order.
///
/// Insert and delete carry the page's template, strokes and images, so undoing a delete restores the page
/// with its content and undoing an insert removes exactly what was inserted. Indices are positions at the moment
/// the edit is applied: a multi-page delete is recorded highest index first, so its inverse re-inserts
/// lowest first and every stored index stays valid.
public enum PageStructureEdit: Hashable, Sendable {
    /// Inserts `page` at `index` with `template`, `strokes` and `images` (empty for a new page).
    case insert(PageID, at: Int, template: PageTemplate, strokes: [Stroke], images: [PageImage] = [])
    /// Removes `page`, currently at `index`; `strokes` and `images` are its content at that time.
    case delete(PageID, at: Int, template: PageTemplate, strokes: [Stroke], images: [PageImage] = [])
    /// Moves the page at `from` so it ends up at `to`.
    case move(from: Int, to: Int)

    /// The edit that undoes this one when applied to the order this one produced.
    public func inverse() -> PageStructureEdit {
        switch self {
        case let .insert(id, index, template, strokes, images):
            .delete(id, at: index, template: template, strokes: strokes, images: images)
        case let .delete(id, index, template, strokes, images):
            .insert(id, at: index, template: template, strokes: strokes, images: images)
        case let .move(from, to): .move(from: to, to: from)
        }
    }

    /// The page inserted or deleted; `nil` for a move.
    public var pageID: PageID? {
        switch self {
        case let .insert(id, _, _, _, _), let .delete(id, _, _, _, _): id
        case .move: nil
        }
    }

    /// A page about to be deleted: what its ``delete(_:at:template:strokes:images:)`` step needs.
    public struct Removal: Hashable, Sendable {
        public var id: PageID
        public var index: Int
        public var template: PageTemplate
        public var strokes: [Stroke]
        public var images: [PageImage]

        public init(id: PageID, index: Int, template: PageTemplate, strokes: [Stroke], images: [PageImage] = []) {
            self.id = id
            self.index = index
            self.template = template
            self.strokes = strokes
            self.images = images
        }
    }

    /// Delete steps for `pages`, ordered so each index is valid when applied after the ones before it
    /// (highest index first).
    public static func deleting(_ pages: [Removal]) -> [PageStructureEdit] {
        pages.sorted { $0.index > $1.index }
            .map { .delete($0.id, at: $0.index, template: $0.template, strokes: $0.strokes, images: $0.images) }
    }
}
