import InkEngine
import InkModel
import PencilKit
import UIKit

/// Off-main rasterization inputs (all `Sendable`). Ink is drawn by PencilKit from the exact stored
/// strokes (``PencilKitConversion/pkStroke(from:color:)``), so a raster matches the canvas.
struct RenderJob: Sendable {
    let page: PageSnapshot
    let palette: any InkPalette
    let theme: PaperTheme
    /// Strokes on the canvas not yet in `page` (drawn last, as on the canvas).
    var pending: [PKStroke] = []

    /// PencilKit adapts ink for dark appearance; the canvas is pinned to light (the palette already
    /// resolved colors for the paper), so rasters render light too.
    private static let traits = UITraitCollection(userInterfaceStyle: .light)

    var isEmpty: Bool {
        page.strokes.isEmpty && pending.isEmpty
    }

    /// Ink only, transparent, page space at `scale` px/pt.
    func ink(scale: CGFloat) -> CGImage? {
        ink(in: CGRect(origin: .zero, size: page.size), scale: scale)
    }

    /// Ink only, transparent, `rect` (page space) at `scale` px/pt.
    func ink(in rect: CGRect, scale: CGFloat) -> CGImage? {
        let drawing = drawing()
        var image: CGImage?
        Self.traits.performAsCurrent {
            image = drawing.image(from: rect, scale: scale).cgImage
        }
        return image
    }

    /// Paper + template + ink scaled into `size` points at `scale`.
    func page(size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = true
        let sx = size.width / page.size.width
        let sy = size.height / page.size.height
        var inkImage: UIImage?
        if !isEmpty {
            let drawing = drawing()
            Self.traits.performAsCurrent {
                inkImage = drawing.image(from: CGRect(origin: .zero, size: page.size), scale: scale * max(sx, sy))
            }
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.scaleBy(x: sx, y: sy)
            TemplatePaths.drawBackground(
                page.page.template,
                size: page.size,
                paper: palette.paper(theme).cgColor,
                line: palette.templateLine(theme).cgColor,
                in: cg
            )
            inkImage?.draw(in: CGRect(origin: .zero, size: page.size))
        }
        return image.cgImage
    }

    func drawing() -> PKDrawing {
        PKDrawing(strokes: page.strokes.map { stroke in
            PencilKitConversion.pkStroke(from: stroke, color: UIColor(palette.ink(stroke.color, on: theme)))
        } + pending)
    }
}
