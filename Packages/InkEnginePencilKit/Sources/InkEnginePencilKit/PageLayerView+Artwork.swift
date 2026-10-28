import InkModel
import QuartzCore
import UIKit

/// Imported artwork (#119): a PDF page in an ``ArtworkLayer`` under the template marks.
extension PageLayerView {
    /// Adds or drops the artwork layer (a page's artwork is set once) and keeps it at the page's bounds.
    func layoutArtwork(_ artwork: (any PageArtwork)?) {
        if (artwork == nil) != (artworkLayer == nil) {
            artworkLayer?.removeFromSuperlayer()
            artworkLayer = artwork.map(ArtworkLayer.init)
            if let artworkLayer {
                artworkLayer.contentsScale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
                layer.insertSublayer(artworkLayer, below: linesLayer)
            }
        }
        if let artworkLayer, artworkLayer.frame != bounds {
            artworkLayer.frame = bounds
        }
    }
}
