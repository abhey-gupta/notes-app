import InkEngine
import InkModel
import PencilKit
import UIKit

/// Off-main rasterization inputs (all `Sendable`).
struct RenderJob: Sendable {
    let page: PageSnapshot
    let palette: any InkPalette
    let theme: PaperTheme

    /// Ink only, transparent, page space at `scale` px/pt.
    func ink(scale: CGFloat) -> CGImage? {
        drawing().image(from: CGRect(origin: .zero, size: page.size), scale: scale).cgImage
    }

    /// Paper + template + ink scaled into `size` points at `scale`.
    func page(size: CGSize, scale: CGFloat) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = scale
        format.opaque = true
        let sx = size.width / page.size.width
        let sy = size.height / page.size.height
        let inkImage = page.strokes.isEmpty ? nil : drawing().image(
            from: CGRect(origin: .zero, size: page.size),
            scale: scale * max(sx, sy)
        )
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

    private func drawing() -> PKDrawing {
        PKDrawing(strokes: page.strokes.map { stroke in
            PencilKitConversion.pkStroke(from: stroke, color: UIColor(palette.ink(stroke.color, on: theme)))
        })
    }
}
