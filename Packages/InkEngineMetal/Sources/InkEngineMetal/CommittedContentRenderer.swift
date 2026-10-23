import CoreGraphics
import InkModel
import Metal

/// Committed content for one frame: the target's pixel size and the visible pages.
struct ContentScene {
    var pixelWidth: Int
    var pixelHeight: Int
    var pages: [ScenePage]
    var blend: HighlightBlend
}

/// Supplies committed page content (paper, template, highlighters, ink) beneath the live stroke.
///
/// The live path stays the same whatever the implementation: each frame calls ``prepare(_:commandBuffer:)``
/// (cheap when nothing changed) and then ``draw(in:)`` as the first draw of the drawable pass, then
/// draws pending and live ink on top. Today ``ViewportCompositeRenderer`` keeps one offscreen texture
/// of the whole viewport; the tile cache (#22, ARCHITECTURE.md §5.4) replaces it with a renderer that
/// keeps per-page tiles, re-renders only tiles intersecting invalidated rects (``setNeedsUpdate(page:rect:)``)
/// and draws tile quads. Both render page content with ``SceneEncoder``.
@MainActor
protocol CommittedContentRenderer: AnyObject {
    /// Content changed: in `rect` (page space) of `page`, all of `page` (`rect == nil`), or everything
    /// (`page == nil`: viewport, theme, layout).
    func setNeedsUpdate(page: PageID?, rect: CGRect?)
    /// Encodes whatever offscreen work is needed before ``draw(in:)`` can show `scene`.
    /// - Returns: Whether anything was rendered.
    @discardableResult
    func prepare(_ scene: ContentScene, commandBuffer: any MTLCommandBuffer) -> Bool
    /// Draws the prepared content into the frame pass (a target of the scene's pixel size).
    func draw(in encoder: any MTLRenderCommandEncoder)
    /// Offscreen re-renders so far (tests, HUD).
    var renderCount: Int { get }
}

/// Interim committed-content renderer: one viewport-sized texture, re-rendered only when the viewport,
/// pages, theme or committed ink change. A live-stroke frame just copies it (one fullscreen triangle).
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

    func setNeedsUpdate(page _: PageID?, rect _: CGRect?) {
        isDirty = true
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
        if coverage == nil, scene.pages.contains(where: { !($0.buffers?.highlightGroups.isEmpty ?? true) }) {
            coverage = gpu.makeTarget(width: scene.pixelWidth, height: scene.pixelHeight, label: "ink.composite.coverage")
        }
        let coverage = coverage
        SceneEncoder.encode(
            scene.pages,
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
