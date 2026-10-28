import InkEngine
import InkGeometry
import InkModel
import PencilKit
import UIKit

/// Off-main rasterization inputs (all `Sendable`). Ink is drawn by PencilKit from the exact stored
/// strokes (``PencilKitConversion/pkStroke(from:color:)``), so a raster matches the canvas; highlights
/// are painted first by ``Highlight`` (#120), as the page view layers them.
struct RenderJob: Sendable {
    /// What a render includes.
    struct Layers: OptionSet, Sendable {
        let rawValue: UInt8
        /// Highlighter bands, beneath the ink.
        static let highlights = Layers(rawValue: 1)
        /// PencilKit ink.
        static let ink = Layers(rawValue: 2)
        static let all: Layers = [.highlights, .ink]
    }

    /// A decoded photo and where it draws (page space), for ``page(size:scale:)`` (#157).
    struct Photo: Sendable {
        let image: CGImage
        let frame: CGRect
    }

    let page: PageSnapshot
    let palette: any InkPalette
    let theme: PaperTheme
    /// The page's photos, bottom to top, drawn over the template (thumbnails and export fallback only;
    /// a page view draws its own photo layers).
    var photos: [Photo] = []
    /// Ink strokes on the canvas not yet in `page` (drawn last, as on the canvas).
    var pending: [PKStroke] = []
    /// Highlights committed but not yet in `page` (drawn after the page's).
    var pendingHighlights: [Stroke] = []
    /// What ``ink(in:scale:)`` renders: everything for thumbnails and the lifted image; ink only for a
    /// page's raster, whose view draws the highlights itself.
    var layers: Layers = .all

    /// PencilKit adapts ink for dark appearance; the canvas is pinned to light (the palette already
    /// resolved colors for the paper), so rasters render light too.
    private static let traits = UITraitCollection(userInterfaceStyle: .light)

    /// Nothing to draw in ``layers``.
    var isEmpty: Bool {
        inkStrokes.isEmpty && highlights.isEmpty
    }

    /// The page's ink strokes (no highlights), if ``layers`` has ink.
    private var inkStrokes: [Stroke] {
        layers.contains(.ink) ? page.strokes.filter { !Highlight.isHighlight($0) } : []
    }

    private var hasPendingInk: Bool {
        layers.contains(.ink) && !pending.isEmpty
    }

    /// The highlights to paint, in order, if ``layers`` has them.
    private var highlights: [Stroke] {
        layers.contains(.highlights) ? page.strokes.filter(Highlight.isHighlight) + pendingHighlights : []
    }

    /// ``layers`` only, transparent, page space at `scale` px/pt.
    func ink(scale: CGFloat) -> CGImage? {
        ink(in: CGRect(origin: .zero, size: page.size), scale: scale)
    }

    /// ``layers`` only, transparent, `rect` (page space) at `scale` px/pt.
    func ink(in rect: CGRect, scale: CGFloat) -> CGImage? {
        var inkImage: UIImage?
        if !inkStrokes.isEmpty || hasPendingInk {
            let drawing = drawing()
            Self.traits.performAsCurrent {
                inkImage = drawing.image(from: rect, scale: scale)
            }
        }
        let highlights = highlights
        guard !highlights.isEmpty else { return inkImage?.cgImage }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -rect.minX, y: -rect.minY)
            Highlight.draw(highlights, color: highlightColor, in: cg)
            inkImage?.draw(in: rect)
        }.cgImage
    }

    private func highlightColor(_ stroke: Stroke) -> CGColor {
        Highlight.color(UIColor(palette.ink(stroke.color, on: theme)))
    }

    /// Paper + template + ink scaled into `size` points at `scale`.
    func page(size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = true
        let sx = size.width / page.size.width
        let sy = size.height / page.size.height
        var inkImage: UIImage?
        if !inkStrokes.isEmpty || hasPendingInk {
            let drawing = drawing()
            Self.traits.performAsCurrent {
                inkImage = drawing.image(from: CGRect(origin: .zero, size: page.size), scale: scale * max(sx, sy))
            }
        }
        let highlights = highlights
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: sx, y: sy)
            TemplateGeometry.drawBackground(
                page.page.template,
                size: page.size,
                leftExtension: page.leftExtension,
                paper: palette.paper(theme).cgColor,
                line: palette.templateLine(theme).cgColor,
                in: cg
            )
            for photo in photos {
                UIImage(cgImage: photo.image).draw(in: photo.frame)
            }
            Highlight.draw(highlights, color: highlightColor, in: cg)
            inkImage?.draw(in: CGRect(origin: .zero, size: page.size))
        }
        return image.cgImage
    }

    /// The ink strokes (no highlights) as PencilKit draws them.
    func drawing() -> PKDrawing {
        PKDrawing(strokes: inkStrokes.map { stroke in
            PencilKitConversion.pkStroke(from: stroke, color: UIColor(palette.ink(stroke.color, on: theme)))
        } + pending)
    }
}
