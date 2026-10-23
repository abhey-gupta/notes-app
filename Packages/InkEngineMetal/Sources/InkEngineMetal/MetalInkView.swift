import InkEngine
import Metal
import QuartzCore
import UIKit

/// The engine's view: a `CAMetalLayer` sized to the viewport (never the content), with the shared
/// ``InkEngine/InkInputView`` on top for touches.
///
/// Layer setup (ARCHITECTURE.md §3.3): `framebufferOnly`, two drawables (one less frame of queueing
/// than the default three), not opaque (the desk shows through between pages), BGRA8 tagged sRGB:
/// palette colors are sRGB and Core Animation color-matches them to the P3 panel. iOS always presents
/// in sync with the display (`displaySyncEnabled` is macOS-only).
@MainActor
final class MetalInkView: UIView {
    override static var layerClass: AnyClass {
        CAMetalLayer.self
    }

    let input = InkInputView()
    /// Called after the drawable size changed.
    var onResize: (() -> Void)?

    var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! CAMetalLayer
    }

    init(device: any MTLDevice) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        let layer = metalLayer
        layer.device = device
        layer.pixelFormat = GPUContext.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.maximumDrawableCount = 2
        layer.isOpaque = false
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        input.frame = bounds
        input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(input)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Device pixels per view point.
    var pixelScale: CGFloat {
        max(window?.screen.scale ?? traitCollection.displayScale, 1)
    }

    /// Drawable size in pixels.
    var pixelSize: (width: Int, height: Int) {
        let size = metalLayer.drawableSize
        return (Int(size.width), Int(size.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = pixelScale
        contentScaleFactor = scale
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
        onResize?()
    }
}
