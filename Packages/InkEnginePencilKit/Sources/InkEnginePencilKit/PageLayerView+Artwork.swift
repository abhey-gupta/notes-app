import InkModel
import QuartzCore
import UIKit

/// Imported artwork (#119): a PDF page in an ``ArtworkLayer`` under the template marks; the engine
/// feeds the layer its bitmaps (`PencilKitInkEngine+Artwork`, #193).
extension PageLayerView {
    /// Adds or drops the artwork layer (a page's artwork is set once) and keeps it at the page's bounds.
    func layoutArtwork(_ artwork: (any PageArtwork)?) {
        if (artwork == nil) != (artworkLayer == nil) {
            artworkLayer?.removeFromSuperlayer()
            artworkLayer = artwork.map(ArtworkLayer.init)
            if let artworkLayer {
                layer.insertSublayer(artworkLayer, below: linesLayer)
            }
        }
        if let artworkLayer, artworkLayer.frame != bounds {
            artworkLayer.frame = bounds
        }
    }

    /// The page has no artwork, or its artwork layer shows a bitmap (any bucket). Until then the
    /// thumbnail (artwork baked in) stays over the empty layer (#193).
    var isArtworkReady: Bool {
        artworkLayer?.hasImage ?? true
    }

    /// The artwork layer got a bitmap: the thumbnail goes if the ink has settled too.
    func artworkDidChange() {
        guard showsThumbnail else { return }
        if shownKey != nil {
            hideThumbnail(animated: true)
        } else if inkLayer.image != nil {
            hideThumbnail(animated: false)
        }
    }
}
