import CoreGraphics
import InkEngine
import InkGeometry
import InkModel
import Metal
import Perf

/// A stroke drawn over committed content this frame (pending, live, overlay).
private struct FrameStroke {
    enum Source {
        /// Index into this frame's ring upload.
        case upload(Int)
        /// A pending stroke's own buffer.
        case buffer(any MTLBuffer)
    }

    var source: Source
    var vertexCount: Int
    var style: StrokeStyle
    var transform: PageTransform
    var scissor: MTLScissorRect
    var isHighlight: Bool
}

/// Live geometry before placement.
private struct FrameShape {
    var vertices: [StrokeVertex]
    var style: StrokeStyle
    var isHighlight: Bool
}

/// Draws one-stroke strips (pipeline already set).
private func draw(_ strokes: [FrameStroke], upload: (buffer: any MTLBuffer, offsets: [Int])?, _ encoder: any MTLRenderCommandEncoder) {
    for stroke in strokes {
        switch stroke.source {
        case let .buffer(buffer):
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        case let .upload(i):
            guard let upload else { continue }
            encoder.setVertexBuffer(upload.buffer, offset: upload.offsets[i], index: 0)
        }
        var transform = stroke.transform
        var style = stroke.style
        encoder.setScissorRect(stroke.scissor)
        encoder.setVertexBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 2)
        encoder.setFragmentBytes(&style, length: MemoryLayout<StrokeStyle>.stride, index: 0)
        encoder.setFragmentBytes(&transform, length: MemoryLayout<PageTransform>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: stroke.vertexCount)
    }
}

/// The drawable's size and scale for one frame.
struct FrameTarget {
    var width: Int
    var height: Int
    var bounds: CGSize
    var pixelsPerPoint: CGFloat
}

extension MetalInkEngine {
    /// Draws and presents one frame. Called inside touch events with the newest touch timestamp
    /// (latency probe), and from the display link for everything else.
    func drawFrame(touchTimestamp: TimeInterval? = nil) {
        let (width, height) = hostView.pixelSize
        let bounds = hostView.bounds.size
        guard width > 0, height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let signpost = Signpost.canvasFrame.begin()
        defer { signpost.end() }
        let target = FrameTarget(width: width, height: height, bounds: bounds, pixelsPerPoint: CGFloat(width) / bounds.width)
        guard let drawable = hostView.metalLayer.nextDrawable(), let commandBuffer = gpu.frameQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "ink.frame"
        content.prepare(makeScene(target), commandBuffer: commandBuffer)
        // Tiles that just landed may already show pending strokes: stop drawing them on top in the
        // same frame, so nothing is drawn twice or vanishes.
        prunePending()

        var uploads: [[StrokeVertex]] = []
        let strokes = frameStrokes(target, uploads: &uploads)
        let upload = ring.upload(uploads)

        // Highlighters over committed content: coverage first (no self-overlap darkening). Multiply
        // and screen commute, so drawing them over committed ink until the next composite looks the
        // same as beneath for dark ink on light paper (and light ink on Night).
        let highlights = strokes.filter(\.isHighlight)
        let coverage = highlights.isEmpty ? nil : frameCoverageTexture(width: width, height: height)
        if let coverage, let encoder = SceneEncoder.beginPass(coverage, load: .clear, MTLClearColor(), commandBuffer, "frame.coverage") {
            encoder.setRenderPipelineState(gpu.pipelines.coverageSingle)
            draw(highlights, upload: upload, encoder)
            encoder.endEncoding()
        }

        guard let encoder = SceneEncoder.beginPass(drawable.texture, load: .clear, MTLClearColor(), commandBuffer, "frame") else {
            ring.finish(nil)
            return
        }
        content.draw(in: encoder)
        if let coverage {
            SceneEncoder.resolveHighlights(coverage, blend: HighlightBlend(theme), encoder, gpu.pipelines)
        }
        encoder.setRenderPipelineState(gpu.pipelines.inkSingle)
        draw(strokes.filter { !$0.isHighlight }, upload: upload, encoder)
        encoder.endEncoding()

        if let touchTimestamp {
            latency.track(drawable, touchTimestamp: touchTimestamp)
        }
        commandBuffer.present(drawable)
        ring.finish(commandBuffer)
        commandBuffer.commit()
        frameCount += 1
    }

    /// Pending strokes (own buffers), then the live gesture (tessellated now and appended to `uploads`:
    /// it changes every event).
    private func frameStrokes(_ target: FrameTarget, uploads: inout [[StrokeVertex]]) -> [FrameStroke] {
        func place(_ id: PageID) -> (transform: PageTransform, scissor: MTLScissorRect)? {
            guard let page = viewport.page(id),
                  let scissor = SceneEncoder.scissor(
                      viewport.viewRect(of: page),
                      pixelsPerPoint: target.pixelsPerPoint,
                      targetWidth: target.width,
                      targetHeight: target.height
                  ) else { return nil }
            let transform = PageTransform(
                pageToTarget: viewport.pageToView(page),
                targetSize: target.bounds,
                pixelsPerPoint: target.pixelsPerPoint
            )
            return (transform, scissor)
        }

        var strokes: [FrameStroke] = []
        for (id, list) in pending {
            guard let at = place(id) else { continue }
            for entry in list {
                guard let buffer = entry.buffer else { continue }
                strokes.append(FrameStroke(
                    source: .buffer(buffer),
                    vertexCount: entry.vertexCount,
                    style: StrokeStyle(kind: entry.stroke.tool, ink: palette.ink(entry.stroke.color, on: theme), ends: entry.ends),
                    transform: at.transform,
                    scissor: at.scissor,
                    isHighlight: entry.stroke.tool == .highlighter
                ))
            }
        }
        if let live, let at = place(live.stroke.page), let shape = liveShape(live, zoom: Float(viewport.zoomScale)) {
            uploads.append(shape.vertices)
            strokes.append(FrameStroke(
                source: .upload(uploads.count - 1),
                vertexCount: shape.vertices.count,
                style: shape.style,
                transform: at.transform,
                scissor: at.scissor,
                isHighlight: shape.isHighlight
            ))
        }
        return strokes
    }

    /// Committed content for the current viewport: the visible pages plus, for tile prefetch, up to
    /// ``tileRadius`` neighbours on each side in ``Viewport/pages`` (hosts pass visible ± 1 frames there;
    /// off-screen pages are never drawn). Each page shows the paper of the theme its last build was
    /// made for, so paper and ink never disagree during a theme switch.
    func makeScene(_ target: FrameTarget) -> ContentScene {
        let scissors = viewport.pages.map { page in
            SceneEncoder.scissor(
                viewport.viewRect(of: page),
                pixelsPerPoint: target.pixelsPerPoint,
                targetWidth: target.width,
                targetHeight: target.height
            )
        }
        let shown = scissors.indices.filter { scissors[$0] != nil }
        var pages: [ScenePage] = []
        if let first = shown.first, let last = shown.last {
            let lo = max(first - Self.tileRadius, 0)
            let hi = min(last + Self.tileRadius, viewport.pages.count - 1)
            for i in lo ... hi {
                pages.append(scenePage(viewport.pages[i], scissor: scissors[i], target))
            }
        }
        return ContentScene(
            pixelWidth: target.width,
            pixelHeight: target.height,
            pages: pages,
            blend: HighlightBlend(theme),
            pointSize: target.bounds,
            pixelsPerPoint: target.pixelsPerPoint,
            zoomScale: viewport.zoomScale
        )
    }

    private func scenePage(_ page: VisiblePage, scissor: MTLScissorRect?, _ target: FrameTarget) -> ScenePage {
        let buffers = pageBuffers[page.id]
        let shown = buffers?.theme ?? theme
        return ScenePage(
            transform: PageTransform(
                pageToTarget: viewport.pageToView(page),
                targetSize: target.bounds,
                pixelsPerPoint: target.pixelsPerPoint
            ),
            background: BackgroundUniforms(
                template: snapshots[page.id]?.page.template ?? .blank,
                size: page.frame.size,
                paper: palette.paper(shown),
                line: palette.templateLine(shown)
            ),
            buffers: buffers,
            scissor: scissor ?? MTLScissorRect(),
            id: page.id,
            size: page.frame.size,
            viewRect: viewport.viewRect(of: page),
            isVisible: scissor != nil
        )
    }

    private func frameCoverageTexture(width: Int, height: Int) -> (any MTLTexture)? {
        if let texture = frameCoverage, texture.width == width, texture.height == height {
            return texture
        }
        frameCoverage = gpu.makeTarget(width: width, height: height, label: "ink.frame.coverage")
        return frameCoverage
    }

    /// The live gesture's geometry: the pen stroke with its predicted tail, the dashed lasso path, or
    /// the eraser outline. Overlay widths are constant on screen (divided by zoom).
    private func liveShape(_ live: Live, zoom: Float) -> FrameShape? {
        let samples = live.stroke.displaySamples
        guard let last = samples.last else { return nil }
        let overlayInk = palette.ink(.primary, on: theme)
        let z = max(zoom, 0.01)
        switch live.tool.tool {
        case let .pen(kind):
            let mesh = StrokeGeometry.mesh(samples: samples, width: live.tool.width, kind: kind, fringe: PageBuilder.fringe)
            let style = StrokeStyle(kind: kind, ink: palette.ink(live.tool.color, on: theme), ends: mesh.ends)
            return FrameShape(vertices: mesh.vertices, style: style, isHighlight: kind == .highlighter)
        case .lasso:
            let path = samples.map { Sample(x: $0.x, y: $0.y, t: $0.t) }
            let mesh = StrokeTessellator.mesh(for: Centerline(samples: path, width: 1.25 / z, profile: .ballpoint), fringe: 1 / z)
            var color = overlayInk.simd
            color.w *= 0.7
            return FrameShape(vertices: mesh.vertices, style: StrokeStyle(color: color, dash: 5 / z), isHighlight: false)
        case .eraser:
            let radius = max(live.tool.width / 2, 2 / z)
            let ring = (0 ... 64).map { i in
                let a = Float(i) / 64 * 2 * .pi
                return Sample(x: last.x + radius * cos(a), y: last.y + radius * sin(a), t: Float(i) / 240)
            }
            let mesh = StrokeTessellator.mesh(for: Centerline(samples: ring, width: 1 / z, profile: .ballpoint), fringe: 1 / z)
            var color = overlayInk.simd
            color.w *= 0.45
            return FrameShape(vertices: mesh.vertices, style: StrokeStyle(color: color), isHighlight: false)
        }
    }
}
