import InkModel
import PencilKit
import UIKit

/// One visible page: paper color, vector template marks, and (unless it is the active page, whose ink
/// the `PKCanvasView` draws) a raster of its ink.
@MainActor
final class PageLayerView: UIView {
    private let linesLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    let inkLayer = CALayer()

    private var templateKey: TemplateKey?

    private struct TemplateKey: Equatable {
        var template: PageTemplate
        var size: CGSize
        var zoom: CGFloat
    }

    /// Paper fill and template mark colors.
    struct Colors {
        var paper: CGColor
        var line: CGColor
    }

    /// Identifies the ink raster currently shown or being rendered.
    var inkKey: InkKey?

    struct InkKey: Hashable {
        var rev: UInt64
        var theme: PaperTheme
        var pixelScale: CGFloat
        var strokeCount: Int
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        linesLayer.fillColor = nil
        linesLayer.lineWidth = TemplatePaths.lineWidth
        dotsLayer.strokeColor = nil
        inkLayer.contentsGravity = .resize
        layer.addSublayer(linesLayer)
        layer.addSublayer(dotsLayer)
        layer.addSublayer(inkLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Lays out at `frame` (view space) for a page of `size` at `zoom`.
    func layout(frame: CGRect, template: PageTemplate, size: CGSize, zoom: CGFloat, colors: Colors) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        layer.backgroundColor = colors.paper
        linesLayer.strokeColor = colors.line
        dotsLayer.fillColor = colors.line
        linesLayer.frame = bounds
        dotsLayer.frame = bounds
        inkLayer.frame = bounds
        let key = TemplateKey(template: template, size: size, zoom: zoom)
        if templateKey != key {
            templateKey = key
            let paths = TemplatePaths(template, size: size)
            var scale = CGAffineTransform(scaleX: zoom, y: zoom)
            linesLayer.path = paths.lines.copy(using: &scale)
            dotsLayer.path = paths.dots.copy(using: &scale)
        }
        CATransaction.commit()
    }

    func setInk(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.contents = image
        CATransaction.commit()
    }

    var showsInk: Bool {
        get { !inkLayer.isHidden }
        set {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            inkLayer.isHidden = !newValue
            CATransaction.commit()
        }
    }
}
