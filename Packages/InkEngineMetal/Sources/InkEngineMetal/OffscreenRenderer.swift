import CoreGraphics
import InkEngine
import InkGeometry
import InkModel
import Metal

/// `render(page:size:scale:)`: one page into an offscreen texture on the background queue, read back
/// as an opaque sRGB `CGImage`. Runs entirely off main.
enum OffscreenRenderer {
    /// Largest texture side we allocate (px).
    static let maximumDimension = 16384

    struct Job: Sendable {
        let gpu: GPUContext
        let page: PageSnapshot
        let size: CGSize
        let scale: CGFloat
        let theme: PaperTheme
        let palette: any InkPalette
        /// Engine-cached geometry (used when the fringe matches).
        let cached: [StrokeID: StrokeGeometry]
    }

    @concurrent
    static func render(_ job: Job) async -> CGImage? {
        let width = Int((job.size.width * job.scale).rounded())
        let height = Int((job.size.height * job.scale).rounded())
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              job.page.size.width > 0, job.page.size.height > 0,
              let commandBuffer = job.gpu.backgroundQueue.makeCommandBuffer(),
              let readback = encode(job, width: width, height: height, into: commandBuffer) else { return nil }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in done.resume() }
            commandBuffer.commit()
        }
        guard commandBuffer.status == .completed else { return nil }
        let data = Data(bytes: readback.contents(), count: width * height * 4)
        return makeImage(bgra: data, width: width, height: height)
    }

    /// Encodes the page and a copy of the result into a shared buffer (returned).
    private static func encode(_ job: Job, width: Int, height: Int, into commandBuffer: any MTLCommandBuffer) -> (any MTLBuffer)? {
        let gpu = job.gpu
        let sx = job.size.width / job.page.size.width
        let sy = job.size.height / job.page.size.height
        let transform = PageTransform(pageToTarget: CGAffineTransform(scaleX: sx, y: sy), targetSize: job.size, pixelsPerPoint: job.scale)
        // Keep the AA fringe ≥ 1 px when the page is drawn smaller than 1 px/pt (thumbnails).
        let fringe = transform.ppp >= 1 ? PageBuilder.fringe : min(1 / max(transform.ppp, 1e-3), StrokeTessellator.maxFringe)
        let build = PageBuilder.buildNow(
            PageBuildInput(snapshot: job.page, theme: job.theme, palette: job.palette, fringe: fringe, cached: job.cached),
            device: gpu.device
        )
        guard let target = gpu.makeTarget(width: width, height: height, label: "ink.offscreen"),
              let readback = gpu.device.makeBuffer(length: width * height * 4, options: .storageModeShared) else { return nil }
        commandBuffer.label = "ink.offscreen"
        let page = ScenePage(
            transform: transform,
            background: BackgroundUniforms(
                template: job.page.page.template,
                size: job.page.size,
                paper: job.palette.paper(job.theme),
                line: job.palette.templateLine(job.theme)
            ),
            buffers: build.buffers,
            scissor: MTLScissorRect(x: 0, y: 0, width: width, height: height)
        )
        SceneEncoder.encode(
            [page],
            into: SceneTarget(texture: target, coverage: { gpu.makeTarget(width: width, height: height, label: "ink.offscreen.coverage") }),
            blend: HighlightBlend(job.theme),
            pipelines: gpu.pipelines,
            commandBuffer: commandBuffer
        )
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback,
            destinationOffset: 0,
            destinationBytesPerRow: width * 4,
            destinationBytesPerImage: width * height * 4
        )
        blit.endEncoding()
        return readback
    }

    /// Opaque sRGB image over BGRA8 bytes.
    static func makeImage(bgra data: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}
