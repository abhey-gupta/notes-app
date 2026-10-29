import CoreGraphics
import InkModel
import QuartzCore

/// A page's imported artwork (a PDF page, #119) as one bitmap of the whole page, rendered off main at
/// the page's zoom bucket and cached across visits (``ArtworkRasterCache``, #193), plus an optional
/// **detail** sublayer: the visible part of the page at full screen resolution when the zoom outgrows the
/// bitmap (`maximumRasterDimension` caps it). The layer scales whatever bitmap it holds to its bounds,
/// so a lower bucket stands in, slightly soft, while the right one renders; nothing draws in squares.
///
/// Replaces a `CATiledLayer` (one `drawPDFPage` per 512 px tile, serialized on the PDF's lock, lost with
/// the layer): a PDF page costs one interpretation per bucket and reappears at once on the way back.
final class ArtworkLayer: CALayer {
    /// Identifies one whole-page bitmap.
    struct Key: Hashable {
        /// Page size the bitmap covers (a widened page, #129, re-renders).
        var size: CGSize
        /// Pixels per point.
        var pixelScale: CGFloat
    }

    /// Identifies one detail render: `rect` (page space) at `pixelScale`.
    struct DetailKey: Hashable {
        var rect: CGRect
        var pixelScale: CGFloat
    }

    let artwork: (any PageArtwork)?
    /// The bitmap on screen, `nil` while the first one renders.
    private(set) var shownKey: Key?
    /// The bitmap asked for (cache hit or render in flight).
    var requestedKey: Key?
    /// The detail on screen.
    private(set) var shownDetail: DetailKey?
    /// The detail render in flight.
    var requestedDetail: DetailKey?

    private let detailLayer = CALayer()

    init(artwork: any PageArtwork) {
        self.artwork = artwork
        super.init()
        isOpaque = true
        contentsGravity = .resize
        // A 2× bitmap shown at zoom 0.5 is minified 4×: trilinear keeps text from shimmering.
        minificationFilter = .trilinear
        magnificationFilter = .linear
        detailLayer.isOpaque = true
        detailLayer.contentsGravity = .resize
        detailLayer.minificationFilter = .trilinear
        detailLayer.magnificationFilter = .linear
        detailLayer.isHidden = true
        addSublayer(detailLayer)
    }

    override init(layer: Any) {
        let other = layer as? ArtworkLayer
        artwork = other?.artwork
        shownKey = other?.shownKey
        shownDetail = other?.shownDetail
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Something is on screen (any bucket).
    var hasImage: Bool {
        contents != nil
    }

    /// Shows the whole-page bitmap `image` rendered for `key`. A detail on screen stays (the engine
    /// clears it once the bitmap the zoom wants is on screen).
    func setImage(_ image: CGImage, key: Key) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = image
        shownKey = key
        CATransaction.commit()
    }

    /// Shows `image`, the artwork over `key.rect` of the page at `key.pixelScale`, on top of the bitmap.
    func setDetail(_ image: CGImage, key: DetailKey) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.contents = image
        detailLayer.frame = key.rect
        detailLayer.isHidden = false
        shownDetail = key
        CATransaction.commit()
    }

    /// Drops the detail (the bitmap is sharp enough, or the page view is being reused).
    func clearDetail() {
        guard shownDetail != nil || requestedDetail != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.isHidden = true
        detailLayer.contents = nil
        shownDetail = nil
        requestedDetail = nil
        CATransaction.commit()
    }

    /// Renders `artwork` over the whole page of `size` at `pixelScale` px/pt (opaque, white paper under it).
    nonisolated static func renderImage(_ artwork: any PageArtwork, size: CGSize, pixelScale: CGFloat) -> CGImage? {
        render(artwork, rect: CGRect(origin: .zero, size: size), pageSize: size, pixelScale: pixelScale)
    }

    /// Renders `artwork` over `rect` (page space) of a page of `pageSize`, at `pixelScale` px/pt.
    nonisolated static func render(_ artwork: any PageArtwork, rect: CGRect, pageSize: CGSize, pixelScale: CGFloat) -> CGImage? {
        let width = Int((rect.width * pixelScale).rounded(.up))
        let height = Int((rect.height * pixelScale).rounded(.up))
        guard width > 0, height > 0, pageSize.width > 0, pageSize.height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.setShouldAntialias(true)
        context.setShouldSmoothFonts(true)
        // CGContext is y-up; page space is y-down: flip, then move `rect`'s origin to the context's.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: pixelScale, y: -pixelScale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        artwork.draw(in: context, size: pageSize)
        return context.makeImage()
    }
}
