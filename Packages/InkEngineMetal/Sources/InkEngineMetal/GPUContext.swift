import Foundation
import Metal
import os

/// Device, queues and pipeline states, shared by every engine in the process (created lazily on
/// first engine init, so app launch never touches Metal; ARCHITECTURE.md §11).
final class GPUContext: Sendable {
    /// Every target (drawable, composite, coverage, offscreen) uses this format; values are
    /// sRGB-encoded and premultiplied.
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: any MTLDevice
    /// Main-thread frames (live stroke, composite updates).
    let frameQueue: any MTLCommandQueue
    /// Offscreen renders (thumbnails, raster export), off main.
    let backgroundQueue: any MTLCommandQueue
    let pipelines: Pipelines

    /// Render pipelines, one per pass type.
    struct Pipelines: Sendable {
        /// Page strokes in one indexed draw, premultiplied over.
        let inkBatched: any MTLRenderPipelineState
        /// One stroke, premultiplied over.
        let inkSingle: any MTLRenderPipelineState
        /// Page highlighters into the coverage target, max blend.
        let coverageBatched: any MTLRenderPipelineState
        /// One highlighter into the coverage target, max blend.
        let coverageSingle: any MTLRenderPipelineState
        /// Coverage → target, multiply (light paper).
        let resolveMultiply: any MTLRenderPipelineState
        /// Coverage → target, screen (Night paper).
        let resolveScreen: any MTLRenderPipelineState
        /// Paper + procedural template.
        let background: any MTLRenderPipelineState
        /// Committed-content texture → frame.
        let composite: any MTLRenderPipelineState
        /// Tile / thumbnail region → frame (bilinear).
        let tile: any MTLRenderPipelineState
    }

    enum Failure: Error {
        case noDevice, noQueue, noLibrary
    }

    /// The process-wide context, or `nil` where Metal is unavailable.
    static let shared: GPUContext? = {
        do {
            return try GPUContext()
        } catch {
            Logger(subsystem: "com.abhey.notespace", category: "ink.metal").fault("Metal unavailable: \(String(describing: error))")
            return nil
        }
    }()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let frameQueue = device.makeCommandQueue(), let backgroundQueue = device.makeCommandQueue() else { throw Failure.noQueue }
        frameQueue.label = "ink.frame"
        backgroundQueue.label = "ink.background"
        let library = try device.makeDefaultLibrary(bundle: .module)
        self.device = device
        self.frameQueue = frameQueue
        self.backgroundQueue = backgroundQueue
        pipelines = try Pipelines(device: device, library: library)
    }
}

extension GPUContext.Pipelines {
    private enum Blend {
        case none, over, max, multiply, screen
    }

    init(device: any MTLDevice, library: any MTLLibrary) throws {
        func make(_ label: String, _ vertex: String, _ fragment: String, _ blend: Blend) throws -> any MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = label
            guard let v = library.makeFunction(name: vertex), let f = library.makeFunction(name: fragment) else {
                throw GPUContext.Failure.noLibrary
            }
            desc.vertexFunction = v
            desc.fragmentFunction = f
            let color = desc.colorAttachments[0]
            color?.pixelFormat = GPUContext.pixelFormat
            switch blend {
            case .none:
                color?.isBlendingEnabled = false
            case .over:
                color?.isBlendingEnabled = true
                color?.sourceRGBBlendFactor = .one
                color?.sourceAlphaBlendFactor = .one
                color?.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .max:
                color?.isBlendingEnabled = true
                color?.rgbBlendOperation = .max
                color?.alphaBlendOperation = .max
            case .multiply:
                color?.isBlendingEnabled = true
                color?.sourceRGBBlendFactor = .destinationColor
                color?.destinationRGBBlendFactor = .zero
                color?.sourceAlphaBlendFactor = .zero
                color?.destinationAlphaBlendFactor = .one
            case .screen:
                color?.isBlendingEnabled = true
                color?.sourceRGBBlendFactor = .oneMinusDestinationColor
                color?.destinationRGBBlendFactor = .one
                color?.sourceAlphaBlendFactor = .zero
                color?.destinationAlphaBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        inkBatched = try make("ink.batched", "stroke_vertex_batched", "stroke_fragment", .over)
        inkSingle = try make("ink.single", "stroke_vertex_single", "stroke_fragment", .over)
        coverageBatched = try make("highlight.coverage.batched", "stroke_vertex_batched", "highlight_coverage_fragment", .max)
        coverageSingle = try make("highlight.coverage.single", "stroke_vertex_single", "highlight_coverage_fragment", .max)
        resolveMultiply = try make("highlight.multiply", "fullscreen_vertex", "highlight_multiply_fragment", .multiply)
        resolveScreen = try make("highlight.screen", "fullscreen_vertex", "highlight_screen_fragment", .screen)
        background = try make("background", "background_vertex", "background_fragment", .none)
        composite = try make("composite", "fullscreen_vertex", "composite_fragment", .none)
        tile = try make("tile", "tile_vertex", "tile_fragment", .none)
    }
}
