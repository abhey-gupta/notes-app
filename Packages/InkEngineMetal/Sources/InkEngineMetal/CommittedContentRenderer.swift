import CoreGraphics
import InkModel
import Metal

/// Committed content for one frame: the target's size, the visible pages (plus, for tiles, their
/// on-layout neighbours, ``ScenePage/isVisible`` `false`) and the zoom.
struct ContentScene {
    var pixelWidth: Int
    var pixelHeight: Int
    var pages: [ScenePage]
    var blend: HighlightBlend
    /// Target size in view points.
    var pointSize: CGSize = .zero
    /// Target pixels per view point.
    var pixelsPerPoint: CGFloat = 1
    /// Page points → view points.
    var zoomScale: CGFloat = 1

    var visiblePages: [ScenePage] {
        pages.filter(\.isVisible)
    }
}

/// Supplies committed page content (paper, template, highlighters, ink) beneath the live stroke.
///
/// The live path stays the same whatever the implementation: each frame calls ``prepare(_:commandBuffer:)``
/// (cheap when nothing changed) and then ``draw(in:)`` as the first draw of the drawable pass, then
/// draws pending and live ink on top. ``TiledContentRenderer`` (ARCHITECTURE.md §5.4) keeps per-page
/// tiles rendered off main and re-renders only tiles intersecting invalidated rects;
/// ``ViewportCompositeRenderer`` (one viewport-sized texture re-rendered on any change) stays for A/B.
/// Both render page content with ``SceneEncoder``.
@MainActor
protocol CommittedContentRenderer: AnyObject {
    /// `page`'s committed content changed within `rect` (page space; `nil`: anywhere on the page).
    func invalidate(page: PageID, rect: CGRect?)
    /// What's shown changed (viewport, target size, page set or builds), not the content of any page.
    func setNeedsDisplay()
    /// Encodes whatever offscreen work is needed before ``draw(in:)`` can show `scene`. Never waits.
    /// - Returns: Whether anything was rendered into `commandBuffer`.
    @discardableResult
    func prepare(_ scene: ContentScene, commandBuffer: any MTLCommandBuffer) -> Bool
    /// Draws the prepared content into the frame pass (a target of the scene's pixel size).
    func draw(in encoder: any MTLRenderCommandEncoder)
    /// Whether everything the last prepared frame shows of `page` reflects its newest invalidation
    /// (pending strokes are drawn on top until then). `true` for pages not shown.
    func isSettled(page: PageID) -> Bool
    /// Offscreen re-renders so far (composites or tiles; tests, HUD).
    var renderCount: Int { get }
}

/// Committed content as one viewport-sized texture, re-rendered whenever the viewport, pages, theme or
/// committed ink change (so every scroll frame re-renders the visible pages). A live-stroke frame just
/// copies it (one fullscreen triangle). Kept behind ``CommittedContentMode/viewportComposite`` for A/B
/// against tiles until device verification.
@MainActor
final class ViewportCompositeRenderer: CommittedContentRenderer {
    private let gpu: GPUContext
    private var composite: (any MTLTexture)?
    private var coverage: (any MTLTexture)?
    private var isDirty = true
    private(set) var renderCount = 0

    init(gpu: GPUContext) {
        self.gpu = gpu
    }

    func invalidate(page _: PageID, rect _: CGRect?) {
        isDirty = true
    }

    func setNeedsDisplay() {
        isDirty = true
    }

    /// Re-renders in the frame's own command buffer, so whatever it shows is current.
    func isSettled(page _: PageID) -> Bool {
        !isDirty
    }

    @discardableResult
    func prepare(_ scene: ContentScene, commandBuffer: any MTLCommandBuffer) -> Bool {
        guard scene.pixelWidth > 0, scene.pixelHeight > 0 else { return false }
        if composite?.width != scene.pixelWidth || composite?.height != scene.pixelHeight {
            composite = gpu.makeTarget(width: scene.pixelWidth, height: scene.pixelHeight, label: "ink.composite")
            coverage = nil
            isDirty = true
        }
        guard isDirty, let composite else { return false }
        let pages = scene.visiblePages
        if coverage == nil, pages.contains(where: { !($0.buffers?.highlightGroups.isEmpty ?? true) }) {
            coverage = gpu.makeTarget(width: scene.pixelWidth, height: scene.pixelHeight, label: "ink.composite.coverage")
        }
        let coverage = coverage
        SceneEncoder.encode(
            pages,
            into: SceneTarget(texture: composite, coverage: { coverage }),
            blend: scene.blend,
            pipelines: gpu.pipelines,
            commandBuffer: commandBuffer
        )
        isDirty = false
        renderCount += 1
        return true
    }

    func draw(in encoder: any MTLRenderCommandEncoder) {
        guard let composite else { return }
        encoder.setRenderPipelineState(gpu.pipelines.composite)
        encoder.setFragmentTexture(composite, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// GPU bytes held.
    var byteCount: Int {
        [composite, coverage].reduce(0) { $0 + ($1.map { $0.width * $0.height * 4 } ?? 0) }
    }
}

extension GPUContext {
    /// A private render target that shaders can read.
    func makeTarget(width: Int, height: Int, label: String, storage: MTLStorageMode = .private) -> (any MTLTexture)? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = storage
        let texture = device.makeTexture(descriptor: desc)
        texture?.label = label
        return texture
    }
}
