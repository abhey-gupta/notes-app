import InkModel
import PencilKit
import UIKit

/// One visible page in content space: paper color, vector template marks, and a raster of its ink
/// (outside ``inkHole``, the part a `PKCanvasView` has drawn).
///
/// The raster is only ever replaced, never cleared ahead of its successor, so ink never blinks out while
/// a new raster renders. The view sits in the host's zoom view, so zoom is the ancestor's transform; the
/// template marks re-rasterize at ``layout(frame:template:markScale:colors:)``'s `markScale` to stay crisp.
@MainActor
final class PageLayerView: UIView {
    private let linesLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    let inkLayer = CALayer()

    private var templateKey: TemplateKey?

    private struct TemplateKey: Equatable {
        var template: PageTemplate
        var size: CGSize
    }

    /// Paper fill and template mark colors.
    struct Colors {
        var paper: CGColor
        var line: CGColor
    }

    /// The raster being rendered (or shown) for this page.
    var requestedKey: InkKey?
    /// The raster on screen, `nil` if none or a stale stand-in.
    private(set) var shownKey: InkKey?

    /// Identifies one raster of a page's ink.
    struct InkKey: Hashable {
        var rev: UInt64
        var theme: PaperTheme
        var pixelScale: CGFloat
        var strokeCount: Int
        /// Strokes drawn on the canvas but not yet echoed into the snapshot.
        var pendingCount: Int
    }

    /// A page-space rect the raster leaves out (the canvas has drawn it).
    var inkHole: CGRect? {
        didSet {
            if inkHole != oldValue {
                updateInkHole()
            }
        }
    }

    private var holeMask: CAShapeLayer?

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

    /// Lays out at `frame` (content space, the page's size) with `template`; `markScale` (px per pt,
    /// `nil` to keep the current one) is the template layers' `contentsScale`.
    func layout(frame: CGRect, template: PageTemplate, markScale: CGFloat?, colors: Colors) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.frame = frame
        layer.backgroundColor = colors.paper
        linesLayer.strokeColor = colors.line
        dotsLayer.fillColor = colors.line
        linesLayer.frame = bounds
        dotsLayer.frame = bounds
        inkLayer.frame = bounds
        let key = TemplateKey(template: template, size: frame.size)
        if templateKey != key {
            templateKey = key
            let paths = TemplatePaths(template, size: frame.size)
            linesLayer.path = paths.lines
            dotsLayer.path = paths.dots
        }
        if let markScale, linesLayer.contentsScale != markScale {
            linesLayer.contentsScale = markScale
            dotsLayer.contentsScale = markScale
        }
        updateInkHole()
        CATransaction.commit()
    }

    /// Shows the raster for `key` (`nil` image: the page has no ink).
    func setInk(_ image: CGImage?, key: InkKey?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.contents = image
        shownKey = key
        CATransaction.commit()
    }

    /// Shows an out-of-date raster of this page while the current one renders (better than no ink).
    func setStaleInk(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.contents = image
        shownKey = nil
        CATransaction.commit()
    }

    /// Forgets which raster is shown so the next refresh renders again (the content stays on screen).
    func invalidateInk() {
        requestedKey = nil
        shownKey = nil
    }

    private func updateInkHole() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let inkHole else {
            inkLayer.mask = nil
            holeMask = nil
            return
        }
        let mask = holeMask ?? CAShapeLayer()
        mask.fillRule = .evenOdd
        mask.frame = inkLayer.bounds
        let path = CGMutablePath()
        path.addRect(inkLayer.bounds)
        path.addRect(inkHole)
        mask.path = path
        if holeMask == nil {
            holeMask = mask
            inkLayer.mask = mask
        }
    }
}
