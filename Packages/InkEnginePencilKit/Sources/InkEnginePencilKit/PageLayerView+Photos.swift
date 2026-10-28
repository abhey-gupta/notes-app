import InkModel
import UIKit

/// A page view's photo layers (#157): one `CALayer` per placed image, framed in page points, beneath the
/// highlights and the ink.
extension PageLayerView {
    /// Shows `images` (in order) as one layer each, keeping the layers of images that are still there.
    /// `bitmap` gives an image's decoded bytes, `nil` while they load (a faint placeholder shows the frame).
    /// Images in `lifted` draw at their frame moved by `transform` (lasso drag preview); the rest in place.
    func setPhotos(
        _ images: [PageImage],
        lifted: Set<ImageID> = [],
        transform: CGAffineTransform = .identity,
        bitmap: (ImageAssetID) -> CGImage?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var kept: [ImageID: CALayer] = [:]
        kept.reserveCapacity(images.count)
        var ordered: [CALayer] = []
        ordered.reserveCapacity(images.count)
        for image in images {
            let layer = photoLayers[image.id] ?? Self.makePhotoLayer()
            let frame = lifted.contains(image.id) ? image.frame.applying(transform) : image.frame
            if layer.frame != frame {
                layer.frame = frame
            }
            let cg = bitmap(image.asset)
            if (layer.contents as AnyObject?) !== cg {
                layer.contents = cg
                layer.backgroundColor = cg == nil ? Self.photoPlaceholder : nil
            }
            kept[image.id] = layer
            ordered.append(layer)
        }
        photoLayers = kept
        if photosLayer.sublayers ?? [] != ordered {
            photosLayer.sublayers = ordered
        }
    }

    /// The photo layers on show, in order (tests).
    var photoSublayers: [CALayer] {
        photosLayer.sublayers ?? []
    }

    private static let photoPlaceholder = CGColor(gray: 0.5, alpha: 0.12)

    private static func makePhotoLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        layer.magnificationFilter = .linear
        layer.masksToBounds = true
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
        return layer
    }
}
