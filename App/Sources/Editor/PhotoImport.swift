import CoreGraphics
import UIKit

/// Preparing a picked photo for a page (#157): the bytes stored in the notebook, and where the photo lands.
enum PhotoImport {
    /// Longest edge kept, in pixels: enough for a full page at 2× zoom on a 2× screen, small enough that a
    /// notebook of photos stays light.
    static let maximumPixelEdge: CGFloat = 2048
    /// A new photo's width as a fraction of the page width.
    static let widthFraction: CGFloat = 0.4
    /// A new photo's height is capped to this fraction of the visible part of the page.
    static let visibleHeightFraction: CGFloat = 0.6
    /// HEIC quality when the system encoder is unavailable (JPEG fallback).
    static let jpegQuality: CGFloat = 0.9

    /// A prepared photo: encoded bytes and their pixel size.
    struct Prepared: Sendable {
        let data: Data
        let pixelSize: CGSize
    }

    /// Decodes `data`, bakes in its orientation, downscales to ``maximumPixelEdge`` and re-encodes as HEIC
    /// (JPEG if HEIC encoding is unavailable). `nil` if `data` isn't an image. Runs anywhere but main.
    nonisolated static func prepare(_ data: Data) -> Prepared? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let factor = min(1, maximumPixelEdge / max(pixels.width, pixels.height))
        let target = CGSize(width: max(1, (pixels.width * factor).rounded(.down)), height: max(1, (pixels.height * factor).rounded(.down)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let encoded = rendered.heicData() ?? rendered.jpegData(compressionQuality: jpegQuality) else { return nil }
        return Prepared(data: encoded, pixelSize: target)
    }

    /// Where a photo of `pixelSize` lands on a page of `pageSize` whose `visible` part (page space) is on
    /// screen: ``widthFraction`` of the page wide, aspect kept, no taller than ``visibleHeightFraction`` of
    /// the visible part, centered in it and kept on the page.
    static func frame(pixelSize: CGSize, visible: CGRect, pageSize: CGSize) -> CGRect {
        let page = CGRect(origin: .zero, size: pageSize)
        let overlap = visible.intersection(page)
        let area = overlap.isEmpty ? page : overlap
        let aspect = pixelSize.height / max(pixelSize.width, 1)
        var width = pageSize.width * widthFraction
        var height = width * aspect
        let maxHeight = max(area.height * visibleHeightFraction, 24)
        if height > maxHeight {
            height = maxHeight
            width = height / max(aspect, 0.001)
        }
        var origin = CGPoint(x: area.midX - width / 2, y: area.midY - height / 2)
        origin.x = min(max(origin.x, 0), max(pageSize.width - width, 0))
        origin.y = min(max(origin.y, 0), max(pageSize.height - height, 0))
        return CGRect(origin: origin, size: CGSize(width: width, height: height)).integral
    }

    #if DEBUG
        /// A 1200×800 landscape test photo (sky-to-sand gradient with a dark disc), JPEG, for `-insertSamplePhoto`.
        static func samplePhotoData() -> Data {
            let size = CGSize(width: 1200, height: 800)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                let cg = context.cgContext
                let sky = UIColor(red: 0.50, green: 0.70, blue: 0.84, alpha: 1).cgColor
                let sand = UIColor(red: 0.94, green: 0.79, blue: 0.53, alpha: 1).cgColor
                let colors = [sky, sand]
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
                }
                cg.setFillColor(UIColor(red: 0.18, green: 0.44, blue: 0.58, alpha: 1).cgColor)
                cg.fillEllipse(in: CGRect(x: 760, y: 120, width: 260, height: 260))
            }
            return image.jpegData(compressionQuality: 0.9) ?? Data()
        }
    #endif
}
