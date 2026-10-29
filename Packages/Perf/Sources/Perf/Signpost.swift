import os

/// Fixed signpost names for every budget in ARCHITECTURE.md §11.
/// Subsystem `com.abhey.notespace`, category = prefix before the dot.
/// Names are API: Instruments templates and `XCTOSSignpostMetric` match on them. Don't rename.
public enum Signpost: String, CaseIterable, Sendable {
    case launchFirstFrame = "launch.firstFrame"
    case notebookOpen = "notebook.open"
    case canvasFirstSharpTile = "canvas.firstSharpTile"
    case canvasFrame = "canvas.frame"
    case tileRender = "tile.render"
    case strokeCommit = "stroke.commit"
    case docCheckpoint = "doc.checkpoint"
    case thumbRender = "thumb.render"
    case exportPDF = "export.pdf"
    case pageImageRender = "page.image.render"
    /// One imported-artwork (PDF page) bitmap or deep-zoom detail render (#193).
    case artworkRender = "page.artwork.render"
    /// Pages overview (#32): Pages tap → the overlay's first frame.
    case pagesOverview = "pages.overview"

    public static let subsystem = "com.abhey.notespace"

    public enum Category: String, CaseIterable, Sendable {
        case launch, notebook, canvas, tile, stroke, doc, thumb, export, page, pages
    }

    public var category: Category {
        switch self {
        case .launchFirstFrame: .launch
        case .notebookOpen: .notebook
        case .canvasFirstSharpTile, .canvasFrame: .canvas
        case .tileRender: .tile
        case .strokeCommit: .stroke
        case .docCheckpoint: .doc
        case .thumbRender: .thumb
        case .exportPDF: .export
        case .pageImageRender, .artworkRender: .page
        case .pagesOverview: .pages
        }
    }

    /// `OSSignposter` needs a `StaticString`; kept in sync with `rawValue` by tests.
    var staticName: StaticString {
        switch self {
        case .launchFirstFrame: "launch.firstFrame"
        case .notebookOpen: "notebook.open"
        case .canvasFirstSharpTile: "canvas.firstSharpTile"
        case .canvasFrame: "canvas.frame"
        case .tileRender: "tile.render"
        case .strokeCommit: "stroke.commit"
        case .docCheckpoint: "doc.checkpoint"
        case .thumbRender: "thumb.render"
        case .exportPDF: "export.pdf"
        case .pageImageRender: "page.image.render"
        case .artworkRender: "page.artwork.render"
        case .pagesOverview: "pages.overview"
        }
    }

    var signposter: OSSignposter {
        category.signposter
    }

    /// Begins an interval. Returns an inert interval (no allocation) when nothing is recording.
    @inline(__always)
    public func begin() -> SignpostInterval {
        let signposter = signposter
        guard signposter.isEnabled else { return SignpostInterval(signpost: self, state: nil) }
        let state = signposter.beginInterval(staticName, id: signposter.makeSignpostID())
        return SignpostInterval(signpost: self, state: state)
    }

    /// Emits a point event.
    @inline(__always)
    public func event() {
        let signposter = signposter
        guard signposter.isEnabled else { return }
        signposter.emitEvent(staticName)
    }

    /// Wraps `body` in an interval.
    @inline(__always)
    public func measure<T>(_ body: () throws -> T) rethrows -> T {
        let interval = begin()
        defer { interval.end() }
        return try body()
    }
}

/// A running signpost interval. Call `end()` exactly once.
public struct SignpostInterval: Sendable {
    public let signpost: Signpost
    let state: OSSignpostIntervalState?

    @inline(__always)
    public func end() {
        guard let state else { return }
        signpost.signposter.endInterval(signpost.staticName, state)
    }
}

extension Signpost.Category {
    private static let launchSP = OSSignposter(subsystem: Signpost.subsystem, category: "launch")
    private static let notebookSP = OSSignposter(subsystem: Signpost.subsystem, category: "notebook")
    private static let canvasSP = OSSignposter(subsystem: Signpost.subsystem, category: "canvas")
    private static let tileSP = OSSignposter(subsystem: Signpost.subsystem, category: "tile")
    private static let strokeSP = OSSignposter(subsystem: Signpost.subsystem, category: "stroke")
    private static let docSP = OSSignposter(subsystem: Signpost.subsystem, category: "doc")
    private static let thumbSP = OSSignposter(subsystem: Signpost.subsystem, category: "thumb")
    private static let exportSP = OSSignposter(subsystem: Signpost.subsystem, category: "export")
    private static let pageSP = OSSignposter(subsystem: Signpost.subsystem, category: "page")
    private static let pagesSP = OSSignposter(subsystem: Signpost.subsystem, category: "pages")

    var signposter: OSSignposter {
        switch self {
        case .launch: Self.launchSP
        case .notebook: Self.notebookSP
        case .canvas: Self.canvasSP
        case .tile: Self.tileSP
        case .stroke: Self.strokeSP
        case .doc: Self.docSP
        case .thumb: Self.thumbSP
        case .export: Self.exportSP
        case .page: Self.pageSP
        case .pages: Self.pagesSP
        }
    }
}
