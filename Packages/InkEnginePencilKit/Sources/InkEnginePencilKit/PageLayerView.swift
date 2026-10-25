import InkGeometry
import InkModel
import PencilKit
import UIKit

/// One visible page in content space: paper color, vector template marks, and an image of its ink
/// (outside ``inkHole``, the part a `PKCanvasView` has drawn; ``HoledImageLayer`` bands, no mask).
///
/// The image is one of (#70's fallback chain, best first): the raster for ``requestedKey``; a stale
/// raster of the page (an older bucket or content, scaled by the layer) while that renders; the page's
/// thumbnail (`thumbs/<id>.heic`, paper and all, scaled up) until there is any raster; nothing but the
/// paper and template layers. An image is only ever replaced, never cleared ahead of its successor, so
/// ink never blinks out. The thumbnail gives way to the first raster with a short crossfade
/// (``crossfadeDuration``, #43); raster-to-raster swaps are instant.
///
/// The view sits in the host's zoom view, so zoom is the ancestor's transform; the template marks
/// re-rasterize at ``layout(frame:template:markScale:colors:)``'s `markScale` to stay crisp.
@MainActor
final class PageLayerView: UIView {
    private let linesLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    /// Holds the thumbnail and ink layers.
    private let imageLayer = CALayer()
    /// The scaled-up thumbnail (opaque: paper, template and ink at thumbnail resolution).
    let thumbnailLayer = HoledImageLayer()
    let inkLayer = HoledImageLayer()

    /// Thumbnail → raster crossfade length, seconds (the app sets it from its motion tokens).
    var crossfadeDuration: TimeInterval = 0.12

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
    /// The thumbnail is on screen (no raster yet).
    private(set) var showsThumbnail = false

    /// Identifies one raster of a page's ink.
    struct InkKey: Hashable {
        var rev: UInt64
        var theme: PaperTheme
        var pixelScale: CGFloat
        var strokeCount: Int
        /// Strokes drawn on the canvas but not yet echoed into the snapshot.
        var pendingCount: Int

        /// What the raster shows, bucket aside.
        var content: ContentKey {
            ContentKey(rev: rev, theme: theme, strokeCount: strokeCount, pendingCount: pendingCount)
        }
    }

    /// A page's ink content at a point in time (every zoom bucket of it shows the same strokes).
    struct ContentKey: Hashable {
        var rev: UInt64
        var theme: PaperTheme
        var strokeCount: Int
        var pendingCount: Int
    }

    /// Something (raster, stale raster or thumbnail) is on screen.
    var hasImage: Bool {
        inkLayer.image != nil || showsThumbnail
    }

    /// A page-space rect the image leaves out (the canvas has drawn it).
    var inkHole: CGRect? {
        didSet {
            if inkHole != oldValue {
                updateInkHole()
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        linesLayer.fillColor = nil
        linesLayer.lineWidth = TemplateGeometry.lineWidth
        dotsLayer.strokeColor = nil
        thumbnailLayer.isHidden = true
        imageLayer.addSublayer(thumbnailLayer)
        imageLayer.addSublayer(inkLayer)
        layer.addSublayer(linesLayer)
        layer.addSublayer(dotsLayer)
        layer.addSublayer(imageLayer)
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
        imageLayer.frame = bounds
        inkLayer.frame = imageLayer.bounds
        layoutThumbnail()
        let key = TemplateKey(template: template, size: frame.size)
        if templateKey != key {
            templateKey = key
            let paths = TemplateGeometry(template, size: frame.size)
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

    /// Shows the raster for `key` (`nil` image: the page has no ink). A thumbnail on screen crossfades out.
    func setInk(_ image: CGImage?, key: InkKey?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.image = image
        shownKey = key
        CATransaction.commit()
        hideThumbnail(animated: true)
    }

    /// Shows an out-of-date raster of this page (older content or another zoom bucket) while the current
    /// one renders: better than no ink.
    func setStaleInk(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        inkLayer.image = image
        shownKey = nil
        CATransaction.commit()
        hideThumbnail(animated: false)
    }

    /// Shows the page's thumbnail scaled to the page width, top-aligned (it is cut at 176×228 pt, so a
    /// taller page's bottom shows the paper and template layers), until a raster lands.
    func setThumbnail(_ image: CGImage) {
        guard inkLayer.image == nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnailLayer.removeAllAnimations()
        thumbnailLayer.image = image
        thumbnailLayer.opacity = 1
        thumbnailLayer.isHidden = false
        showsThumbnail = true
        layoutThumbnail()
        CATransaction.commit()
    }

    private func layoutThumbnail() {
        guard let cg = thumbnailLayer.image, bounds.width > 0 else { return }
        let height = cg.width > 0 ? bounds.width * CGFloat(cg.height) / CGFloat(cg.width) : bounds.height
        thumbnailLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(height, bounds.height))
    }

    private func hideThumbnail(animated: Bool) {
        guard showsThumbnail else { return }
        showsThumbnail = false
        let thumbnail = thumbnailLayer
        guard animated, crossfadeDuration > 0 else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbnail.isHidden = true
            thumbnail.image = nil
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            // A later `setThumbnail` restarted it: leave that one alone.
            guard thumbnail.animation(forKey: "crossfade") == nil, thumbnail.opacity == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbnail.isHidden = true
            thumbnail.image = nil
            CATransaction.commit()
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = crossfadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        thumbnail.opacity = 0
        thumbnail.add(fade, forKey: "crossfade")
        CATransaction.commit()
    }

    /// Both image layers sit at the page's origin, so the hole is the same rect in each.
    private func updateInkHole() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumbnailLayer.hole = inkHole
        inkLayer.hole = inkHole
        CATransaction.commit()
    }
}
