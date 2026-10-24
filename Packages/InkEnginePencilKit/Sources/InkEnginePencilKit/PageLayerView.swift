import InkModel
import PencilKit
import UIKit

/// One visible page: paper color, vector template marks, and (unless the `PKCanvasView` is drawing this
/// page) a raster of its ink.
///
/// The raster is only ever replaced, never cleared ahead of its successor, so ink never blinks out while
/// a new raster renders. A page the canvas just left shows a snapshot of the canvas (``setPlaceholder``)
/// until its raster arrives.
@MainActor
final class PageLayerView: UIView {
    private let linesLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    let inkLayer = CALayer()

    private var templateKey: TemplateKey?
    private var zoom: CGFloat = 1
    /// Snapshot of the canvas shown until the raster for ``requestedKey`` arrives, with its page-space rect.
    private var placeholder: (view: UIView, pageRect: CGRect)?

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

    /// Whether the raster may show (false while the canvas draws this page).
    var showsInk = true {
        didSet { updateInkVisibility() }
    }

    /// A page-space rect the raster leaves out (the canvas covers it), e.g. mid-zoom.
    var inkHole: CGRect? {
        didSet {
            if inkHole != oldValue {
                updateInkHole()
            }
        }
    }

    private var holeMask: CAShapeLayer?

    var hasPlaceholder: Bool {
        placeholder != nil
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
        self.zoom = zoom
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
        if let placeholder {
            placeholder.view.frame = Self.scaled(placeholder.pageRect, by: zoom)
        }
        updateInkHole()
        CATransaction.commit()
    }

    /// Shows the raster for `key` (`nil` image: the page has no ink) and drops any placeholder.
    func setInk(_ image: CGImage?, key: InkKey?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.contents = image
        shownKey = key
        CATransaction.commit()
        removePlaceholder()
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

    /// Covers `pageRect` (page space) with `view` (a snapshot of the canvas) and hides the raster until
    /// ``setInk(_:key:)``.
    func setPlaceholder(_ view: UIView, pageRect: CGRect) {
        removePlaceholder()
        view.isUserInteractionEnabled = false
        view.frame = Self.scaled(pageRect, by: zoom)
        addSubview(view)
        placeholder = (view, pageRect)
        updateInkVisibility()
    }

    func removePlaceholder() {
        guard let placeholder else { return }
        placeholder.view.removeFromSuperview()
        self.placeholder = nil
        updateInkVisibility()
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
        path.addRect(Self.scaled(inkHole, by: zoom))
        mask.path = path
        if holeMask == nil {
            holeMask = mask
            inkLayer.mask = mask
        }
    }

    private func updateInkVisibility() {
        let hidden = !showsInk || placeholder != nil
        guard inkLayer.isHidden != hidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.isHidden = hidden
        CATransaction.commit()
    }

    private static func scaled(_ rect: CGRect, by zoom: CGFloat) -> CGRect {
        CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }
}
