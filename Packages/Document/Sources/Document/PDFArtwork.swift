import CoreGraphics
import Foundation
import InkModel

/// A PDF opened once and shared by the artwork of its pages (#119). CoreGraphics PDF objects aren't
/// documented as thread-safe, so every page access is serialized.
public final class PDFSource: @unchecked Sendable {
    private let document: CGPDFDocument
    private let lock = NSLock()

    /// Opens the PDF at `url`; `nil` if it isn't a readable, unlocked PDF.
    public init?(url: URL) {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked else { return nil }
        self.document = document
    }

    /// `true` if `url` is a PDF that needs a password (import refuses it with its own message).
    public static func isLocked(_ url: URL) -> Bool {
        guard let document = CGPDFDocument(url as CFURL) else { return false }
        return !document.isUnlocked
    }

    /// Number of pages.
    public var pageCount: Int {
        document.numberOfPages
    }

    /// Page `index`'s size in points as displayed (crop box, rotation applied); `nil` out of range.
    public func pageSize(at index: Int) -> CGSize? {
        withPage(index) { Self.displaySize(of: $0) }
    }

    /// Runs `body` with page `index` (zero-based) under the lock; `nil` out of range.
    func withPage<T>(_ index: Int, _ body: (CGPDFPage) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let page = document.page(at: index + 1) else { return nil }
        return body(page)
    }

    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox).standardized
        return abs(page.rotationAngle) % 180 == 90 ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Notebook page size for a PDF whose first page is `size`: that size, unless a side is outside
    /// 200...2000 pt (slivers, posters), then scaled to A4 width so zoom and raster limits stay sane.
    public static func notebookPageSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return Notebook.a4Portrait }
        let range: ClosedRange<CGFloat> = 200 ... 2000
        guard !range.contains(size.width) || !range.contains(size.height) else { return size }
        let width = Notebook.a4Portrait.width
        let height = min(max(width * size.height / size.width, 1), 2000)
        return CGSize(width: width, height: height.rounded())
    }
}

/// Page `pageIndex` of a ``PDFSource`` as page artwork: white paper, then the PDF page aspect-fitted and
/// centered. Vector throughout: drawn into a PDF context it stays the original page's content (export
/// flattens ink onto it), drawn into a bitmap it renders at that bitmap's resolution.
public struct PDFArtwork: PageArtwork {
    public let source: PDFSource
    public let pageIndex: Int

    public init(source: PDFSource, pageIndex: Int) {
        self.source = source
        self.pageIndex = pageIndex
    }

    public func draw(in context: CGContext, size: CGSize) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        _ = source.withPage(pageIndex) { page in
            let natural = PDFSource.displaySize(of: page)
            guard natural.width > 0, natural.height > 0 else { return }
            let scale = min(size.width / natural.width, size.height / natural.height)
            let fitted = CGSize(width: natural.width * scale, height: natural.height * scale)
            // Page space is y-down; PDF space y-up: flip inside the fitted rect.
            context.translateBy(x: (size.width - fitted.width) / 2, y: (size.height + fitted.height) / 2)
            context.scaleBy(x: scale, y: -scale)
            let rect = CGRect(origin: .zero, size: natural)
            // Same-size rect: no scaling, only the crop-box origin and /Rotate.
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.clip(to: page.getBoxRect(.cropBox))
            context.drawPDFPage(page)
        }
    }
}
