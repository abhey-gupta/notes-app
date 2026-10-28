import CoreGraphics
import Foundation
import InkGeometry
import InkModel

/// Strokes and images picked by the lasso on one page (ARCHITECTURE.md §6), with the geometry the selection
/// chrome draws (padded convex ``hull``, its ``bounds`` and four resize corners) and the edits its actions
/// make.
///
/// A value: the session keeps the current one, previews drags with ``applying(_:)`` and, after an edit
/// lands, rebuilds it from the page with ``init(_:images:on:)``. Every action is one undo step of one or
/// two ``PageEdit``s (strokes, images): move/resize → ``transformEdits(_:on:)`` (baked), recolor →
/// ``recolorEdit(to:on:)`` (strokes only), delete → ``removeEdits(on:)``, duplicate →
/// ``duplicateEdits(on:offset:)``.
public struct LassoSelection: Hashable, Sendable {
    /// A resize handle. Dragging one scales the selection proportionally about the opposite corner.
    public enum Corner: CaseIterable, Hashable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft

        /// The corner that stays put while this one is dragged.
        public var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomRight: .topLeft
            case .bottomLeft: .topRight
            }
        }
    }

    /// Duplicates land this far right and down of the originals (pt).
    public static let duplicateOffset: CGFloat = 20
    /// Space between the ink and the hull (pt).
    public static let padding: CGFloat = 2
    /// Resizing never makes the selection's shorter side smaller than this (pt) ...
    public static let minimumSide: CGFloat = 8
    /// ... or its longer side larger than this (pt).
    public static let maximumSide: CGFloat = 4000

    /// Page the strokes are on.
    public let pageID: PageID
    /// Selected strokes, in z-order.
    public let strokeIDs: [StrokeID]
    /// Selected images (#157), in z-order.
    public let imageIDs: [ImageID]
    /// Convex hull around the selected ink and images (outlines plus ``padding``), page space (the
    /// marching ants).
    public let hull: [CGPoint]
    /// Bounding box of ``hull``; the resize corners sit on it.
    public let bounds: CGRect

    /// Resolves a finished lasso path (page space): strokes with at least `threshold` of their samples
    /// inside, and images whose center is inside. `nil` if nothing is selected (a tap, or a loop around
    /// empty paper).
    public init?(lasso path: [CGPoint], on page: Page, threshold: Float = Lasso.selectionThreshold) {
        let lasso = Lasso(path)
        guard lasso.points.count >= 3 else { return nil }
        let strokes = page.strokes.filter { lasso.selects($0, threshold: threshold) }
        let images = page.images.filter { lasso.contains(Point2(x: Float($0.frame.midX), y: Float($0.frame.midY))) }
        self.init(pageID: page.id, strokes: strokes, images: images)
    }

    /// The strokes with `ids` and the images with `images` that are still on `page` (after an edit).
    /// `nil` if none are.
    public init?(_ ids: some Sequence<StrokeID>, images: some Sequence<ImageID> = EmptyCollection(), on page: Page) {
        let wanted = Set(ids)
        let wantedImages = Set(images)
        self.init(
            pageID: page.id,
            strokes: page.strokes.filter { wanted.contains($0.id) },
            images: page.images.filter { wantedImages.contains($0.id) }
        )
    }

    /// The selection an image about to be placed on `page` will have (its frame, before the edit lands).
    public init(placing image: PageImage, on page: PageID) {
        self.init(pageID: page, strokeIDs: [], imageIDs: [image.id], hull: Self.paddedHull([], images: [image]))
    }

    private init?(pageID: PageID, strokes: [Stroke], images: [PageImage]) {
        guard !strokes.isEmpty || !images.isEmpty else { return nil }
        let hull = Self.paddedHull(strokes, images: images)
        guard !hull.isEmpty else { return nil }
        self.init(pageID: pageID, strokeIDs: strokes.map(\.id), imageIDs: images.map(\.id), hull: hull)
    }

    private init(pageID: PageID, strokeIDs: [StrokeID], imageIDs: [ImageID], hull: [CGPoint]) {
        self.pageID = pageID
        self.strokeIDs = strokeIDs
        self.imageIDs = imageIDs
        self.hull = hull
        bounds = Self.boundingBox(hull)
    }

    /// The selection holds strokes (recolor applies).
    public var hasInk: Bool {
        !strokeIDs.isEmpty
    }

    // MARK: Geometry

    /// Where `corner`'s handle sits (page space).
    public func point(of corner: Corner) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: bounds.minX, y: bounds.minY)
        case .topRight: CGPoint(x: bounds.maxX, y: bounds.minY)
        case .bottomRight: CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .bottomLeft: CGPoint(x: bounds.minX, y: bounds.maxY)
        }
    }

    /// Proportional resize for dragging `corner` by `translation` (page space): uniform scale about the
    /// opposite corner, by the drag's projection on the diagonal, clamped to ``minimumSide`` /
    /// ``maximumSide``. Dragging past the anchor doesn't mirror.
    public func resizeTransform(dragging corner: Corner, by translation: CGSize) -> CGAffineTransform {
        let anchor = point(of: corner.opposite)
        let start = point(of: corner)
        let diagonal = CGPoint(x: start.x - anchor.x, y: start.y - anchor.y)
        let length = diagonal.x * diagonal.x + diagonal.y * diagonal.y
        guard length > 0, length.isFinite, translation.width.isFinite, translation.height.isFinite else { return .identity }
        let projected = ((diagonal.x + translation.width) * diagonal.x + (diagonal.y + translation.height) * diagonal.y) / length
        let shorter = max(min(bounds.width, bounds.height), .ulpOfOne)
        let longer = max(bounds.width, bounds.height, .ulpOfOne)
        let lower = min(Self.minimumSide / shorter, 1)
        let upper = max(Self.maximumSide / longer, 1)
        let scale = min(max(projected, lower), upper)
        return CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }

    /// The selection as it looks with `transform` applied (drag preview): same items, mapped hull.
    public func applying(_ transform: CGAffineTransform) -> LassoSelection {
        LassoSelection(pageID: pageID, strokeIDs: strokeIDs, imageIDs: imageIDs, hull: hull.map { $0.applying(transform) })
    }

    // MARK: Edits

    /// Move/resize: bakes `transform` into the strokes and the images (one edit each, as needed). Empty
    /// for the identity (a tap, no movement).
    public func transformEdits(_ transform: CGAffineTransform, on page: Page) throws(PageEditError) -> [PageEdit] {
        guard !transform.isIdentity else { return [] }
        var edits: [PageEdit] = []
        if !strokeIDs.isEmpty {
            try edits.append(page.transformEdit(strokeIDs, by: transform))
        }
        if !imageIDs.isEmpty {
            try edits.append(page.transformImagesEdit(imageIDs, by: transform))
        }
        return edits
    }

    /// Sets every selected stroke to `color`. `nil` if they all have it already.
    public func recolorEdit(to color: InkColor, on page: Page) throws(PageEditError) -> PageEdit? {
        let ids = Set(strokeIDs)
        let changing = page.strokes.filter { ids.contains($0.id) && $0.color != color }.map(\.id)
        guard !changing.isEmpty else { return nil }
        return try page.recolorEdit(changing, to: color)
    }

    /// Deletes the selected strokes and images (one edit each, as needed).
    public func removeEdits(on page: Page) throws(PageEditError) -> [PageEdit] {
        var edits: [PageEdit] = []
        if !strokeIDs.isEmpty {
            try edits.append(page.removeEdit(strokeIDs))
        }
        if !imageIDs.isEmpty {
            try edits.append(page.removeImagesEdit(imageIDs))
        }
        return edits
    }

    /// Copies of the selected strokes and images, `offset` pt right and down, on top of the page (fresh
    /// IDs; copied images share the original's asset; render groups remapped so stroke copies don't
    /// composite with the originals), plus the selection of the copies. `nil` if nothing selected is on
    /// `page`.
    public func duplicateEdits(on page: Page, offset: CGFloat = duplicateOffset) -> (edits: [PageEdit], selection: LassoSelection)? {
        let ids = Set(strokeIDs)
        let wantedImages = Set(imageIDs)
        let move = CGAffineTransform(translationX: offset, y: offset)
        var groups: [UUID: UUID] = [:]
        let copies = page.strokes.filter { ids.contains($0.id) }.map { stroke in
            var rendering = stroke.rendering
            if let group = rendering?.renderGroupID {
                let fresh = groups[group] ?? UUID()
                groups[group] = fresh
                rendering?.renderGroupID = fresh
            }
            return Stroke(
                tool: stroke.tool, color: stroke.color, width: stroke.width, samples: stroke.samples, rendering: rendering
            ).transformed(by: move)
        }
        let imageCopies = page.images.filter { wantedImages.contains($0.id) }.map { image in
            PageImage(asset: image.asset, frame: image.frame).transformed(by: move)
        }
        guard !copies.isEmpty || !imageCopies.isEmpty else { return nil }
        var edits: [PageEdit] = []
        if !copies.isEmpty {
            edits.append(page.addEdit(copies))
        }
        if !imageCopies.isEmpty {
            edits.append(page.addImagesEdit(imageCopies))
        }
        let selection = LassoSelection(
            pageID: page.id, strokeIDs: copies.map(\.id), imageIDs: imageCopies.map(\.id), hull: hull.map { $0.applying(move) }
        )
        return (edits, selection)
    }

    // MARK: Private

    /// Hull of every sample and image corner, each hull vertex outset by the widest stroke's outline reach
    /// plus ``padding``.
    private static func paddedHull(_ strokes: [Stroke], images: [PageImage]) -> [CGPoint] {
        var points: [CGPoint] = []
        points.reserveCapacity(strokes.reduce(0) { $0 + $1.samples.count } + images.count * 4)
        for image in images {
            let f = image.frame.standardized
            guard f.origin.x.isFinite, f.origin.y.isFinite, f.width.isFinite, f.height.isFinite else { continue }
            points.append(CGPoint(x: f.minX, y: f.minY))
            points.append(CGPoint(x: f.maxX, y: f.minY))
            points.append(CGPoint(x: f.maxX, y: f.maxY))
            points.append(CGPoint(x: f.minX, y: f.maxY))
        }
        var reach: CGFloat = 0
        for stroke in strokes where !stroke.samples.isEmpty {
            var minX = CGFloat.infinity
            var maxX = -CGFloat.infinity
            for s in stroke.samples where s.x.isFinite && s.y.isFinite {
                let p = CGPoint(x: CGFloat(s.x), y: CGFloat(s.y))
                points.append(p)
                minX = min(minX, p.x)
                maxX = max(maxX, p.x)
            }
            if maxX >= minX {
                reach = max(reach, (stroke.bounds.width - (maxX - minX)) / 2)
            }
        }
        let core = convexHull(points)
        let radius = reach + padding
        let ring = core.flatMap { p in
            (0 ..< 8).map { k in
                let angle = CGFloat(k) * .pi / 4
                return CGPoint(x: p.x + radius * cos(angle), y: p.y + radius * sin(angle))
            }
        }
        return convexHull(ring)
    }

    /// Andrew's monotone chain. Collinear points dropped; fewer than 3 distinct points come back as-is.
    static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let points = input.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        var unique: [CGPoint] = []
        unique.reserveCapacity(points.count)
        for p in points where unique.last != p {
            unique.append(p)
        }
        guard unique.count >= 3 else { return unique }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in unique {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in unique.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        guard var minX = points.first?.x, var minY = points.first?.y else { return .null }
        var maxX = minX
        var maxY = minY
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
