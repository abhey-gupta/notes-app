import CoreGraphics
import InkModel
import Metal

/// How highlighters combine with the paper beneath them.
enum HighlightBlend {
    /// Light paper: `dst × mix(1, color, coverage)` (ARCHITECTURE.md §3.3).
    case multiply
    /// Night paper, where multiply would all but vanish: the mirrored blend, `1 − (1 − dst)(1 − c)`.
    case screen

    init(_ theme: PaperTheme) {
        self = theme.isDark ? .screen : .multiply
    }
}

/// One page as drawn into a target: where (transform, scissor), its paper and its committed ink.
struct ScenePage {
    var transform: PageTransform
    var background: BackgroundUniforms
    /// `nil` while the page's first build is in flight (paper only).
    var buffers: PageBuffers?
    /// The page's rect in target pixels, clipped to the target. Ink never draws outside its page.
    var scissor: MTLScissorRect
}

/// Where ``SceneEncoder`` draws: a target texture (cleared to transparent) and, on demand, a coverage
/// texture of the same size for highlighters.
struct SceneTarget {
    var texture: any MTLTexture
    /// Allocated only if some page has highlighters.
    var coverage: () -> (any MTLTexture)?
}

/// Encodes committed page content into a texture: paper + template, then highlighters beneath all
/// ink, then ink. Shared by the viewport composite, offscreen renders and (later) tiles.
///
/// Passes, with `G` = most highlighter groups on any page:
/// - `G == 0`: one pass on the target: backgrounds, ink.
/// - otherwise, for each group `k`: a coverage pass (clear, max blend: group `k` of every page; pages
///   don't overlap so they share it), then a target pass (`k == 0`: backgrounds first) that resolves
///   the coverage with multiply/screen; the last target pass also draws the ink.
enum SceneEncoder {
    static func encode(
        _ pages: [ScenePage],
        into target: SceneTarget,
        blend: HighlightBlend,
        pipelines: GPUContext.Pipelines,
        commandBuffer: any MTLCommandBuffer
    ) {
        let groups = pages.map { $0.buffers?.highlightGroups.count ?? 0 }.max() ?? 0
        let coverageTexture = groups > 0 ? target.coverage() : nil
        let clear = MTLClearColor()
        guard let coverageTexture else {
            guard let encoder = beginPass(target.texture, load: .clear, clear, commandBuffer, "scene") else { return }
            drawBackgrounds(pages, encoder, pipelines)
            drawInk(pages, encoder, pipelines)
            encoder.endEncoding()
            return
        }
        for k in 0 ..< groups {
            if let encoder = beginPass(coverageTexture, load: .clear, MTLClearColor(), commandBuffer, "highlight.coverage") {
                encoder.setRenderPipelineState(pipelines.coverageBatched)
                for page in pages {
                    guard let buffers = page.buffers, k < buffers.highlightGroups.count else { continue }
                    encoder.setScissorRect(page.scissor)
                    drawStrips(buffers, range: buffers.highlightGroups[k], transform: page.transform, encoder)
                }
                encoder.endEncoding()
            }
            guard let encoder = beginPass(target.texture, load: k == 0 ? .clear : .load, clear, commandBuffer, "scene") else { continue }
            if k == 0 {
                drawBackgrounds(pages, encoder, pipelines)
            }
            resolveHighlights(coverageTexture, blend: blend, encoder, pipelines)
            if k == groups - 1 {
                drawInk(pages, encoder, pipelines)
            }
            encoder.endEncoding()
        }
    }

    /// Starts a render pass on `texture`.
    static func beginPass(
        _ texture: any MTLTexture,
        load: MTLLoadAction,
        _ clear: MTLClearColor,
        _ commandBuffer: any MTLCommandBuffer,
        _ label: String
    ) -> (any MTLRenderCommandEncoder)? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = load
        pass.colorAttachments[0].clearColor = clear
        pass.colorAttachments[0].storeAction = .store
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        encoder?.label = label
        encoder?.setCullMode(.none)
        return encoder
    }

    /// Composites a coverage target onto the current pass (multiply or screen).
    static func resolveHighlights(
        _ coverage: any MTLTexture,
        blend: HighlightBlend,
        _ encoder: any MTLRenderCommandEncoder,
        _ pipelines: GPUContext.Pipelines
    ) {
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: coverage.width, height: coverage.height))
        encoder.setRenderPipelineState(blend == .multiply ? pipelines.resolveMultiply : pipelines.resolveScreen)
        encoder.setFragmentTexture(coverage, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The page's rect `rect` (target points) in target pixels, clipped; `nil` if nothing is visible.
    static func scissor(_ rect: CGRect, pixelsPerPoint: CGFloat, targetWidth: Int, targetHeight: Int) -> MTLScissorRect? {
        let px = CGRect(
            x: rect.minX * pixelsPerPoint,
            y: rect.minY * pixelsPerPoint,
            width: rect.width * pixelsPerPoint,
            height: rect.height * pixelsPerPoint
        )
        let x0 = max(Int(px.minX.rounded(.down)), 0)
        let y0 = max(Int(px.minY.rounded(.down)), 0)
        let x1 = min(Int(px.maxX.rounded(.up)), targetWidth)
        let y1 = min(Int(px.maxY.rounded(.up)), targetHeight)
        guard x1 > x0, y1 > y0 else { return nil }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    // MARK: Private

    private static func drawBackgrounds(_ pages: [ScenePage], _ encoder: any MTLRenderCommandEncoder, _ pipelines: GPUContext.Pipelines) {
        encoder.setRenderPipelineState(pipelines.background)
        for page in pages {
            var transform = page.transform
            var background = page.background
            encoder.setScissorRect(page.scissor)
            encoder.setVertexBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 2)
            encoder.setVertexBytes(&background, length: MemoryLayout<BackgroundUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&background, length: MemoryLayout<BackgroundUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private static func drawInk(_ pages: [ScenePage], _ encoder: any MTLRenderCommandEncoder, _ pipelines: GPUContext.Pipelines) {
        encoder.setRenderPipelineState(pipelines.inkBatched)
        for page in pages {
            guard let buffers = page.buffers, !buffers.ink.isEmpty else { continue }
            encoder.setScissorRect(page.scissor)
            drawStrips(buffers, range: buffers.ink, transform: page.transform, encoder)
        }
    }

    /// One indexed strip draw over `range` of the page's index buffer (pipeline already set).
    private static func drawStrips(
        _ buffers: PageBuffers,
        range: Range<Int>,
        transform: PageTransform,
        _ encoder: any MTLRenderCommandEncoder
    ) {
        guard !range.isEmpty, let vertices = buffers.vertices, let strokeIndices = buffers.strokeIndices,
              let indices = buffers.indices, let styles = buffers.styles else { return }
        var transform = transform
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBuffer(strokeIndices, offset: 0, index: 1)
        encoder.setVertexBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 2)
        encoder.setFragmentBuffer(styles, offset: 0, index: 0)
        encoder.setFragmentBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 1)
        encoder.drawIndexedPrimitives(
            type: .triangleStrip,
            indexCount: range.count,
            indexType: .uint32,
            indexBuffer: indices,
            indexBufferOffset: range.lowerBound * MemoryLayout<UInt32>.stride
        )
    }
}
