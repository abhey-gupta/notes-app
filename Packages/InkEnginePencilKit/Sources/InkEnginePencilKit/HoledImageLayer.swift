import QuartzCore

/// An image stretched over its bounds except ``hole``, drawn as up to four bands (above, below, left
/// and right of the hole) that show the matching parts of ``image`` via `contentsRect`.
///
/// Replaces an even-odd `mask`: a masked layer costs the render server an offscreen pass every frame,
/// one per visible page (#44); bands are plain image layers.
final class HoledImageLayer: CALayer {
    /// The image, scaled to the bounds.
    var image: CGImage? {
        didSet {
            guard image !== oldValue else { return }
            for band in bands {
                band.contents = image
            }
        }
    }

    /// A rect in this layer's coordinates left out of the image; `nil` shows all of it.
    var hole: CGRect? {
        didSet {
            if hole != oldValue {
                layoutBands()
            }
        }
    }

    /// The bands' magnification filter.
    var imageMagnificationFilter: CALayerContentsFilter = .linear {
        didSet {
            for band in bands {
                band.magnificationFilter = imageMagnificationFilter
            }
        }
    }

    private let bands = (0 ..< 4).map { _ in CALayer() }

    override init() {
        super.init()
        for band in bands {
            band.contentsGravity = .resize
            band.actions = Self.noActions
            addSublayer(band)
        }
        actions = Self.noActions
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        layoutBands()
    }

    /// Frames of the visible bands, in this layer's coordinates (tests).
    var bandFrames: [CGRect] {
        bands.filter { !$0.isHidden }.map(\.frame)
    }

    private func layoutBands() {
        let frames = Self.bands(in: bounds, hole: hole)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, band) in bands.enumerated() {
            guard i < frames.count, bounds.width > 0, bounds.height > 0 else {
                band.isHidden = true
                continue
            }
            let frame = frames[i]
            band.isHidden = false
            band.frame = frame
            band.contentsRect = CGRect(
                x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
                width: frame.width / bounds.width, height: frame.height / bounds.height
            )
        }
        CATransaction.commit()
    }

    /// `bounds` minus `hole` as at most four non-empty rects: full-width above and below, then left and
    /// right of the hole.
    static func bands(in bounds: CGRect, hole: CGRect?) -> [CGRect] {
        guard let hole else { return [bounds] }
        let h = hole.intersection(bounds)
        guard !h.isNull, h.width > 0, h.height > 0 else { return [bounds] }
        return [
            CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: h.minY - bounds.minY),
            CGRect(x: bounds.minX, y: h.maxY, width: bounds.width, height: bounds.maxY - h.maxY),
            CGRect(x: bounds.minX, y: h.minY, width: h.minX - bounds.minX, height: h.height),
            CGRect(x: h.maxX, y: h.minY, width: bounds.maxX - h.maxX, height: h.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }

    private static var noActions: [String: any CAAction] {
        Dictionary(uniqueKeysWithValues: ["bounds", "position", "contents", "contentsRect", "hidden"].map { ($0, NSNull()) })
    }
}
