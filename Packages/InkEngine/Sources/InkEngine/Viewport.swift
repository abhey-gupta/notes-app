import CoreGraphics
import InkModel

/// A page the host currently shows, with its frame in content space (unzoomed points, `PageLayout`).
public struct VisiblePage: Hashable, Sendable, Identifiable {
    /// The page.
    public var id: PageID
    /// Frame in content space.
    public var frame: CGRect

    /// Creates a visible page.
    public init(id: PageID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// What the engine view shows: scroll offset, zoom and the visible pages (ARCHITECTURE.md §5.1).
///
/// Spaces: **page** (pt, origin at the page's top-left) → **content** (`page + frame.origin`, the engine
/// view's space) → **view** (`content × zoomScale − contentOffset`, the scroll view's visible bounds,
/// where the host's overlay lives).
public struct Viewport: Hashable, Sendable {
    /// `UIScrollView.contentOffset`: zoomed content points at the view's top-left.
    public var contentOffset: CGPoint
    /// `UIScrollView.zoomScale`.
    public var zoomScale: CGFloat
    /// Visible size (the scroll view's bounds, pt).
    public var size: CGSize
    /// Visible pages, top to bottom.
    public var pages: [VisiblePage]
    /// A zoom gesture (pinch, or its bounce back into range) is in progress: `zoomScale` changes every
    /// frame until a viewport with this `false` settles it. Engines may defer expensive re-rendering
    /// (the host's zoom transform scales what they last drew; PencilKit re-tiles once at the settled
    /// zoom, ARCHITECTURE.md §3).
    public var isZooming: Bool

    /// Creates a viewport.
    public init(
        contentOffset: CGPoint = .zero,
        zoomScale: CGFloat = 1,
        size: CGSize = .zero,
        pages: [VisiblePage] = [],
        isZooming: Bool = false
    ) {
        self.contentOffset = contentOffset
        self.zoomScale = zoomScale
        self.size = size
        self.pages = pages
        self.isZooming = isZooming
    }

    /// Empty viewport.
    public static let empty = Viewport()

    /// Page space → view space for `page`.
    public func pageToView(_ page: VisiblePage) -> CGAffineTransform {
        CGAffineTransform(
            a: zoomScale, b: 0, c: 0, d: zoomScale,
            tx: page.frame.minX * zoomScale - contentOffset.x,
            ty: page.frame.minY * zoomScale - contentOffset.y
        )
    }

    /// View space → page space for `page`.
    public func viewToPage(_ page: VisiblePage) -> CGAffineTransform {
        pageToView(page).inverted()
    }

    /// `page`'s rect in view space (may extend beyond the view).
    public func viewRect(of page: VisiblePage) -> CGRect {
        CGRect(origin: .zero, size: page.frame.size).applying(pageToView(page))
    }

    /// The visible page containing `point` (view space), if any.
    public func page(at point: CGPoint) -> VisiblePage? {
        pages.first { viewRect(of: $0).contains(point) }
    }

    /// The visible page with `id`.
    public func page(_ id: PageID) -> VisiblePage? {
        pages.first { $0.id == id }
    }

    /// The page whose view rect is nearest the view's center (the page indicator's "current" page).
    public var centerPage: VisiblePage? {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return pages.min { distance(center, viewRect(of: $0)) < distance(center, viewRect(of: $1)) }
    }

    private func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY))
    }
}
