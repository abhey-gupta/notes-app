import InkGeometry
import InkModel
import PencilKit
import UIKit

/// One visible page in content space: paper color, imported artwork (a PDF page, ``ArtworkLayer``, #119),
/// vector template marks, its photos (#157, one layer each, beneath the highlights), its highlights (#120,
/// one shape layer each, multiplied with the page beneath, #196, under everything that draws ink), and an
/// image of its ink (outside ``inkHole``, the part a `PKCanvasView` has drawn; ``HoledImageLayer`` bands, no
/// mask). Pages touch (#162): every page but the first draws a one-pixel hairline in the template mark color
/// along its top edge, over its image.
///
/// The image is one of (#70's fallback chain, best first): the raster for ``requestedKey``; a stale
/// raster of the page (an older bucket or content, scaled by the layer) while that renders; the page's
/// thumbnail (`thumbs/<id>.heic`, paper and all, scaled up) until there is any raster; nothing but the
/// paper and template layers. An image is only ever replaced, never cleared ahead of its successor, so
/// ink never blinks out. The thumbnail gives way to the first raster with a short crossfade
/// (``crossfadeDuration``, #43); raster-to-raster swaps are instant.
///
/// The view sits in the host's zoom view, so zoom is the ancestor's transform; the template marks
/// re-rasterize at ``layout(frame:template:leftExtension:artwork:markScale:colors:)``'s `markScale` to stay crisp.
@MainActor
final class PageLayerView: UIView {
    let linesLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()
    /// Photos in z-order, beneath the highlights and the ink (`+Photos`).
    let photosLayer = CALayer()
    var photoLayers: [ImageID: CALayer] = [:]
    /// Highlight bands in stroke order, the live one (if any) last. Beneath the thumbnail (which has them
    /// baked in) and the ink image; the canvas above draws ink only. Multiplied with the page beneath as
    /// one group (#196): a compositing filter on a band itself only sees this layer's (empty) content.
    private let highlightsLayer = CALayer()
    private var highlightLayers: [StrokeID: (stroke: Stroke, layer: CAShapeLayer)] = [:]
    private var liveHighlight: CAShapeLayer?
    /// Holds the thumbnail and ink layers.
    private let imageLayer = CALayer()
    /// The scaled-up thumbnail (opaque: paper, template and ink at thumbnail resolution).
    let thumbnailLayer = HoledImageLayer()
    let inkLayer = HoledImageLayer()
    /// The seam with the page above (#162), one screen pixel tall; hidden on the first page.
    let seamLayer = CALayer()

    /// Thumbnail → raster crossfade length, seconds (the app sets it from its motion tokens).
    var crossfadeDuration: TimeInterval = 0.12

    private var templateKey: TemplateKey?
    var artworkLayer: ArtworkLayer?

    private struct TemplateKey: Equatable {
        var template: PageTemplate
        var size: CGSize
        var leftExtension: CGFloat
    }

    /// Paper fill and template mark colors.
    struct Colors {
        var paper: CGColor
        var line: CGColor
    }

    /// What the highlight layers show; ``setHighlights(_:key:color:)`` is skipped while it holds.
    private(set) var highlightKey: HighlightKey?

    /// Identifies the set of highlights a page view shows and their colors.
    struct HighlightKey: Hashable {
        var rev: UInt64
        var theme: PaperTheme
        /// Palette generation (`PKStrokeCache.generation`): colors changed.
        var colors: Int
        var pendingCount: Int
        /// Strokes left out (lifted by the selection).
        var hidden: Set<StrokeID>
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
        /// Page size the raster covers: a widened page (#129) re-renders even with the same strokes.
        var size: CGSize = .zero

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
        layer.addSublayer(photosLayer)
        layer.addSublayer(highlightsLayer)
        layer.addSublayer(imageLayer)
        layer.addSublayer(seamLayer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Lays out at `frame` (content space, the page's size) with `template` over `artwork`; `markScale`
    /// (px per pt, `nil` to keep the current one) is the template layers' `contentsScale`. A page's
    /// artwork is set once (it never changes for a page ID). A page that changed size (widened, #129)
    /// drops its image: a raster of the old size would be stretched over the new one.
    func layout(
        frame: CGRect, template: PageTemplate, leftExtension: CGFloat = 0, artwork: (any PageArtwork)? = nil,
        markScale: CGFloat?, colors: Colors
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if bounds.size != .zero, bounds.size != frame.size {
            clearImages()
        }
        self.frame = frame
        layer.backgroundColor = colors.paper
        linesLayer.strokeColor = colors.line
        dotsLayer.fillColor = colors.line
        linesLayer.frame = bounds
        dotsLayer.frame = bounds
        photosLayer.frame = bounds
        highlightsLayer.frame = bounds
        imageLayer.frame = bounds
        inkLayer.frame = imageLayer.bounds
        layoutArtwork(artwork)
        layoutThumbnail()
        let key = TemplateKey(template: template, size: frame.size, leftExtension: leftExtension)
        if templateKey != key {
            templateKey = key
            let paths = TemplateGeometry(template, size: frame.size, leftExtension: leftExtension)
            linesLayer.path = paths.lines
            dotsLayer.path = paths.dots
        }
        if let markScale, linesLayer.contentsScale != markScale {
            linesLayer.contentsScale = markScale
            dotsLayer.contentsScale = markScale
            for sublayer in highlightsLayer.sublayers ?? [] {
                sublayer.contentsScale = markScale
            }
        }
        seamLayer.backgroundColor = colors.line
        seamLayer.isHidden = frame.minY <= 0
        seamLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(linesLayer.contentsScale, 1))
        updateInkHole()
        CATransaction.commit()
    }

    // MARK: Ink image

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
        // Not over a page whose ink settled and whose artwork (if any) is up: it decoded too late.
        guard inkLayer.image == nil, shownKey == nil || !isArtworkReady else { return }
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

    /// Drops the raster and thumbnail (the page's size changed; the next raster is requested afresh).
    private func clearImages() {
        inkLayer.image = nil
        shownKey = nil
        requestedKey = nil
        thumbnailLayer.removeAllAnimations()
        thumbnailLayer.isHidden = true
        thumbnailLayer.image = nil
        showsThumbnail = false
    }

    private func layoutThumbnail() {
        guard let cg = thumbnailLayer.image, bounds.width > 0 else { return }
        let height = cg.width > 0 ? bounds.width * CGFloat(cg.height) / CGFloat(cg.width) : bounds.height
        thumbnailLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: min(height, bounds.height))
    }

    func hideThumbnail(animated: Bool) {
        guard showsThumbnail, isArtworkReady else { return }
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

// MARK: Highlights

extension PageLayerView {
    /// Shows `strokes` (highlights, in order) as one shape layer each, keeping the layers of strokes that
    /// didn't change; the live highlight, if any, stays on top.
    func setHighlights(_ strokes: [Stroke], key: HighlightKey, color: (Stroke) -> CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        highlightKey = key
        Highlight.blend(highlightsLayer, multiply: Highlight.multiplies(on: key.theme, artwork: artworkLayer != nil))
        var kept: [StrokeID: (stroke: Stroke, layer: CAShapeLayer)] = [:]
        kept.reserveCapacity(strokes.count)
        var ordered: [CALayer] = []
        ordered.reserveCapacity(strokes.count + 1)
        for stroke in strokes {
            let layer = highlightLayers[stroke.id]?.layer ?? Self.makeHighlightLayer(contentsScale: linesLayer.contentsScale)
            if highlightLayers[stroke.id]?.stroke != stroke {
                Highlight.configure(layer, stroke: stroke, color: color(stroke))
            } else {
                Highlight.tint(layer, color(stroke))
            }
            kept[stroke.id] = (stroke, layer)
            ordered.append(layer)
        }
        if let liveHighlight {
            ordered.append(liveHighlight)
        }
        highlightLayers = kept
        if highlightsLayer.sublayers ?? [] != ordered {
            highlightsLayer.sublayers = ordered
        }
    }

    /// The highlights' compositing filter (tests).
    var highlightsFilter: String? {
        highlightsLayer.compositingFilter as? String
    }

    /// The layers of the highlights on show, in order (tests).
    var highlightShapeLayers: [CAShapeLayer] {
        (highlightsLayer.sublayers ?? []).compactMap { $0 as? CAShapeLayer }
    }

    /// Puts the band being drawn above the page's highlights.
    func addLiveHighlight(_ layer: CAShapeLayer) {
        liveHighlight?.removeFromSuperlayer()
        layer.contentsScale = linesLayer.contentsScale
        liveHighlight = layer
        highlightsLayer.addSublayer(layer)
    }

    /// The live band is now `stroke`'s layer (no handoff on lift).
    func adoptLiveHighlight(_ layer: CAShapeLayer, as stroke: Stroke) {
        if liveHighlight === layer {
            liveHighlight = nil
        }
        highlightLayers[stroke.id]?.layer.removeFromSuperlayer()
        highlightLayers[stroke.id] = (stroke, layer)
        highlightKey = nil
    }

    private static func makeHighlightLayer(contentsScale: CGFloat) -> CAShapeLayer {
        let layer = Highlight.makeLayer()
        layer.contentsScale = contentsScale
        return layer
    }
}
