import CoreGraphics
import Foundation
import InkGeometry
import InkModel
import os

/// Vector PDF export of a notebook (ARCHITECTURE.md §9).
///
/// One PDF page per notebook page at the notebook's page size. Per page, bottom to top: paper, template
/// (vector lines/dots), highlighter strokes (multiply), brush strokes (raster image from the
/// ``BrushRasterizer`` if any), pen ink. Ink is fitted with cubic Béziers within ~4 % of the stroke width
/// (0.05–0.15 pt): centerlines stroked with round caps/joins in near-constant-width pieces, or filled
/// `InkGeometry` outlines where that doesn't fit (``StrokeShape``). Realistic notes come to ~80 KB per
/// dense page. No text, no fonts.
///
/// Works from in-memory model values (no file format dependency) and runs off the main actor: outlines
/// are computed for batches of pages in parallel, then drawn in order. Cancelling the calling task stops
/// the export and throws `CancellationError`.
public struct PDFExporter: Sendable {
    /// Pixels per point for rasterized brush strokes.
    public static let brushRasterScale: CGFloat = 2

    /// Color source (the app adapts `DesignSystem`).
    public var palette: any PDFPalette
    /// Brush rasterizer; `nil` exports brush strokes as vector fills.
    public var brushRasterizer: (any BrushRasterizer)?

    /// Creates an exporter.
    public init(palette: any PDFPalette, brushRasterizer: (any BrushRasterizer)? = nil) {
        self.palette = palette
        self.brushRasterizer = brushRasterizer
    }

    /// Exports to a new temporary file, `<tmp>/<unique>/<title>.pdf`, for the share sheet. The caller owns
    /// the file (delete it, or its parent directory, when done).
    /// - Parameters:
    ///   - pages: The notebook's pages in order. ``PDFExportOptions/pages`` selects among them.
    ///   - progress: Called with the fraction done (0...1] after each page, from a background task.
    /// - Returns: The file URL.
    @concurrent
    public func exportPDF(
        pages: [Page],
        options: PDFExportOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: Self.fileName(for: options.title), directoryHint: .notDirectory)
        do {
            try await write(pages: pages, options: options, to: url, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return url
    }

    /// Exports to `url`, replacing any file there. On failure the file may be partial; delete it.
    @concurrent
    public func write(
        pages: [Page],
        options: PDFExportOptions,
        to url: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        var box = try Self.mediaBox(options)
        guard let context = CGContext(url as CFURL, mediaBox: &box, Self.auxiliaryInfo(options)) else {
            throw PDFExportError.cannotCreateContext
        }
        try await render(pages: pages, options: options, into: context, progress: progress)
    }

    /// Exports to memory (tests, small exports).
    @concurrent
    public func pdfData(
        pages: [Page],
        options: PDFExportOptions,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
        var box = try Self.mediaBox(options)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, Self.auxiliaryInfo(options))
        else {
            throw PDFExportError.cannotCreateContext
        }
        try await render(pages: pages, options: options, into: context, progress: progress)
        return data as Data
    }

    // MARK: Rendering

    private static let signposter = OSSignposter(subsystem: "com.abhey.notespace", category: "export")

    /// Draws the selected pages into a fresh PDF context and closes it.
    private func render(
        pages: [Page],
        options: PDFExportOptions,
        into context: CGContext,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let state = Self.signposter.beginInterval("export.pdf")
        defer { Self.signposter.endInterval("export.pdf", state) }
        defer { context.closePDF() }

        let selected = try Array(pages[options.pages.indices(pageCount: pages.count)])
        let batchSize = max(4, 2 * ProcessInfo.processInfo.activeProcessorCount)
        var done = 0
        for batchStart in stride(from: 0, to: selected.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(selected[batchStart ..< min(batchStart + batchSize, selected.count)])
            let arts = try await buildArt(for: batch, options: options)
            for art in arts {
                draw(art, options: options, in: context)
                done += 1
                progress?(Double(done) / Double(selected.count))
            }
        }
    }

    /// Builds art for `pages` concurrently; result in input order.
    private func buildArt(for pages: [Page], options: PDFExportOptions) async throws -> [PageArt] {
        let palette = palette
        let rasterizer = brushRasterizer
        return try await withThrowingTaskGroup(of: (Int, PageArt).self) { group in
            for (i, page) in pages.enumerated() {
                group.addTask {
                    try await (i, PageArt.build(
                        page,
                        options: options,
                        palette: palette,
                        rasterizer: rasterizer,
                        rasterScale: Self.brushRasterScale
                    ))
                }
            }
            var out = [PageArt?](repeating: nil, count: pages.count)
            for try await (i, art) in group {
                out[i] = art
            }
            return out.compactMap(\.self)
        }
    }

    private func draw(_ art: PageArt, options: PDFExportOptions, in context: CGContext) {
        let size = options.pageSize
        let theme = options.exportTheme
        context.beginPDFPage(nil)
        context.saveGState()
        // Page space: origin top-left, y down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(palette.paper(theme))
        context.fill(CGRect(origin: .zero, size: size))

        let template = TemplateArt(art.template, pageSize: size)
        if !template.isEmpty {
            let color = palette.templateLine(theme)
            context.setStrokeColor(color)
            context.setFillColor(color)
            context.setLineWidth(TemplateArt.lineWidth)
            context.addPath(template.lines)
            context.strokePath()
            context.addPath(template.dots)
            context.fillPath()
        }

        if !art.highlights.isEmpty {
            context.setBlendMode(.multiply)
            paint(art.highlights, in: context)
            context.setBlendMode(.normal)
        }

        if let image = art.brushImage {
            context.saveGState()
            // Images draw bottom-up; flip back to PDF space for this one.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(origin: .zero, size: size))
            context.restoreGState()
        }

        paint(art.ink, in: context)

        context.restoreGState()
        context.endPDFPage()
    }

    /// Paints each run: outlines filled (nonzero), centerlines stroked with round joins, one stroke
    /// operation per distinct width. Coordinates go out as integers in 0.1 pt units under a 0.1 scale:
    /// shorter numbers in the content stream, ~0.05 pt rounding.
    private func paint(_ runs: [InkRun], in context: CGContext) {
        guard !runs.isEmpty else { return }
        let scale = Self.coordinateScale
        context.saveGState()
        context.scaleBy(x: 1 / scale, y: 1 / scale)
        context.setLineJoin(.round)
        var cap = CGLineCap.round
        context.setLineCap(cap)
        for run in runs {
            if !run.fills.isEmpty {
                let path = CGMutablePath()
                for contour in run.fills {
                    Self.add(contour, to: path)
                    path.closeSubpath()
                }
                context.setFillColor(run.color)
                context.addPath(path)
                context.fillPath(using: .winding)
            }
            guard !run.strokes.isEmpty else { continue }
            if run.cap != cap {
                cap = run.cap
                context.setLineCap(cap)
            }
            context.setStrokeColor(run.color)
            // Widths in 1/20 pt steps (edge error ≤ 0.0125 pt) so pieces of a pen share one operation.
            var byWidth: [Int: CGMutablePath] = [:]
            for piece in run.strokes {
                let key = Int((piece.width * 20).rounded())
                let path = byWidth[key] ?? CGMutablePath()
                Self.add(piece.path, to: path)
                byWidth[key] = path
            }
            for (key, path) in byWidth.sorted(by: { $0.key < $1.key }) {
                context.setLineWidth(CGFloat(max(key, 1)) * scale / 20)
                context.addPath(path)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    /// Appends `contour` as a subpath in ink coordinate units (not closed).
    private static func add(_ contour: CubicContour, to path: CGMutablePath) {
        func q(_ p: Point2) -> CGPoint {
            CGPoint(x: (CGFloat(p.x) * coordinateScale).rounded(), y: (CGFloat(p.y) * coordinateScale).rounded())
        }
        path.move(to: q(contour.start))
        for s in contour.segments {
            if s.isLine {
                path.addLine(to: q(s.end))
            } else {
                path.addCurve(to: q(s.end), control1: q(s.c1), control2: q(s.c2))
            }
        }
    }

    /// Ink coordinate units per point.
    private static let coordinateScale: CGFloat = 10

    // MARK: Helpers

    private static func mediaBox(_ options: PDFExportOptions) throws(PDFExportError) -> CGRect {
        let size = options.pageSize
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
            throw .invalidPageSize
        }
        return CGRect(origin: .zero, size: size)
    }

    private static func auxiliaryInfo(_ options: PDFExportOptions) -> CFDictionary {
        var info: [CFString: Any] = [kCGPDFContextCreator: "Notespace"]
        if let title = options.title {
            info[kCGPDFContextTitle] = title
        }
        return info as CFDictionary
    }

    /// `"<title>.pdf"` with path separators and control characters removed; `"Notebook.pdf"` if empty.
    static func fileName(for title: String?) -> String {
        let cleaned = (title ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        let base = cleaned.isEmpty || cleaned.hasPrefix(".") ? "Notebook" : String(cleaned.prefix(120))
        return base + ".pdf"
    }
}
