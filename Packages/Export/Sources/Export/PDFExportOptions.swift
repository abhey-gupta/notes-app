import CoreGraphics
import InkModel

/// Which pages to export. Indices are zero-based positions in the page array handed to the exporter.
public enum PageSelection: Hashable, Sendable {
    /// Every page.
    case all
    /// One page (the "current page" option).
    case page(Int)
    /// A contiguous range of pages.
    case range(ClosedRange<Int>)

    /// The selected indices for a notebook of `count` pages.
    /// - Throws: ``PDFExportError/pageOutOfRange(_:)`` if the selection reaches past the notebook,
    ///   ``PDFExportError/noPages`` if the notebook is empty.
    public func indices(pageCount count: Int) throws(PDFExportError) -> ClosedRange<Int> {
        guard count > 0 else { throw .noPages }
        let range = switch self {
        case .all: 0 ... count - 1
        case let .page(i): i ... i
        case let .range(r): r
        }
        for i in [range.lowerBound, range.upperBound] where !(0 ..< count).contains(i) {
            throw .pageOutOfRange(i)
        }
        return range
    }
}

/// Why an export failed.
public enum PDFExportError: Error, Hashable, Sendable {
    /// Nothing to export.
    case noPages
    /// The page selection names a page the notebook doesn't have.
    case pageOutOfRange(Int)
    /// Page size is empty or non-finite.
    case invalidPageSize
    /// CoreGraphics couldn't create the PDF context (e.g. unwritable URL).
    case cannotCreateContext
}

/// What to export and how it should look (ARCHITECTURE.md §9).
public struct PDFExportOptions: Hashable, Sendable {
    /// PDF page size in points (the notebook's actual, possibly widened, page size; one PDF page per
    /// notebook page).
    public var pageSize: CGSize
    /// The notebook's paper theme.
    public var theme: PaperTheme
    /// The notebook's "Keep exact colors" setting (custom colors not remapped on Night).
    public var keepsExactColors: Bool
    /// "Export as shown": keep Night paper. Off by default, so Night notebooks export on white paper with
    /// the light ink palette.
    public var exportsAsShown: Bool
    /// Pages to export.
    public var pages: PageSelection
    /// PDF document title (metadata), usually the notebook title.
    public var title: String?

    /// Creates options. Defaults: A4 portrait, white paper, all pages.
    public init(
        pageSize: CGSize = Notebook.a4Portrait,
        theme: PaperTheme = .white,
        keepsExactColors: Bool = false,
        exportsAsShown: Bool = false,
        pages: PageSelection = .all,
        title: String? = nil
    ) {
        self.pageSize = pageSize
        self.theme = theme
        self.keepsExactColors = keepsExactColors
        self.exportsAsShown = exportsAsShown
        self.pages = pages
        self.title = title
    }

    /// Options for `notebook`: its page size (widened pages export at their full width, #129), theme and title.
    public init(notebook: Notebook, pages: PageSelection = .all, exportsAsShown: Bool = false) {
        self.init(
            pageSize: notebook.extendedPageSize,
            theme: notebook.theme,
            exportsAsShown: exportsAsShown,
            pages: pages,
            title: notebook.title
        )
    }

    /// Paper the PDF is drawn on: Night becomes white unless ``exportsAsShown``; other themes are kept.
    /// Ink resolves against this theme (§10).
    public var exportTheme: PaperTheme {
        theme == .night && !exportsAsShown ? .white : theme
    }
}
