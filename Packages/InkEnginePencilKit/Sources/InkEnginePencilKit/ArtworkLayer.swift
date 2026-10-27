import InkModel
import QuartzCore

/// A page's imported artwork (a PDF page, #119) drawn in tiles, off main, at the zoom it is shown at:
/// only the visible part renders, and a PDF stays sharp from 0.5× to 4×. The artwork is fixed for the
/// layer's life (tiles draw on background threads); a page whose artwork changes gets a new layer.
final class ArtworkLayer: CATiledLayer {
    let artwork: (any PageArtwork)?

    init(artwork: any PageArtwork) {
        self.artwork = artwork
        super.init()
        isOpaque = true
        needsDisplayOnBoundsChange = true
        tileSize = CGSize(width: 512, height: 512)
        // Detail levels from 1/2× to 8× the layer's contents scale (zoom 0.5...4 on a 2× screen).
        levelsOfDetail = 5
        levelsOfDetailBias = 3
    }

    override init(layer: Any) {
        artwork = (layer as? ArtworkLayer)?.artwork
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Short: tiles replace a page that already shows its thumbnail.
    override static func fadeDuration() -> CFTimeInterval {
        0.12
    }

    /// Layer space is page space (y down, as in UIKit), so the artwork draws as is.
    override func draw(in context: CGContext) {
        artwork?.draw(in: context, size: bounds.size)
    }
}
