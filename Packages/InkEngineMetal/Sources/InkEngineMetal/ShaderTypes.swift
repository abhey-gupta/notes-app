import CoreGraphics
import InkEngine
import InkGeometry
import InkModel

// Swift mirrors of the structs in `Shaders/Ink.metal`. Field order and SIMD alignment match MSL; the
// layout tests pin sizes and strides.

/// Page space → clip space, plus device pixels per page point.
struct PageTransform: Equatable {
    var scale: SIMD2<Float>
    var offset: SIMD2<Float>
    var ppp: Float
    var pad0: Float = 0
    var pad1: SIMD2<Float> = .zero

    /// Maps `pageToTarget` (page pt → target pt) into a `targetSize` pt target with `pixelsPerPoint`.
    init(pageToTarget t: CGAffineTransform, targetSize: CGSize, pixelsPerPoint: CGFloat) {
        let w = max(targetSize.width, 1)
        let h = max(targetSize.height, 1)
        scale = SIMD2(Float(2 * t.a / w), Float(-2 * t.d / h))
        offset = SIMD2(Float(2 * t.tx / w - 1), Float(1 - 2 * t.ty / h))
        ppp = Float(min(abs(t.a), abs(t.d)) * pixelsPerPoint)
    }
}

/// Per-stroke look.
struct StrokeStyle: Equatable {
    /// Straight-alpha sRGB; `a` = ink alpha × pen opacity.
    var color: SIMD4<Float>
    var softness: Float
    var cap: UInt32
    var texture: UInt32
    var dash: Float
    /// Chisel end planes (``StrokeEnds``), used when `cap` is butt.
    var start: SIMD4<Float>
    var end: SIMD4<Float>
    var length: Float
    var pad0: Float = 0
    var pad1: SIMD2<Float> = .zero

    enum Texture: UInt32 {
        case none = 0, grain = 1, bristles = 2
    }

    init(
        color: SIMD4<Float>,
        softness: Float = 0,
        cap: CapStyle = .round,
        texture: Texture = .none,
        dash: Float = 0,
        ends: StrokeEnds = .none
    ) {
        self.color = color
        self.softness = softness
        self.cap = cap == .butt ? 1 : 0
        self.texture = texture.rawValue
        self.dash = dash
        start = ends.start
        end = ends.end
        length = ends.length
    }

    /// The look of a `kind` pen in `ink` (already resolved for the paper theme), ending at `ends`.
    init(kind: PenKind, ink: RGBA8, ends: StrokeEnds) {
        let profile = PenProfile(kind)
        var color = ink.simd
        color.w *= profile.opacity
        let texture: Texture = switch kind {
        case .ballpoint: .grain
        case .brush: .bristles
        case .fountain, .highlighter: .none
        }
        self.init(color: color, softness: profile.edgeSoftness, cap: profile.capStyle, texture: texture, ends: ends)
    }
}

/// A tile region in the frame: destination in clip space, source in texture coordinates.
struct TileQuad: Equatable {
    /// Clip-space `x0, y0, x1, y1`.
    var dst: SIMD4<Float>
    /// Texture `u0, v0, u1, v1`.
    var uv: SIMD4<Float>
}

/// Procedural page template parameters.
struct BackgroundUniforms: Equatable {
    var paper: SIMD4<Float>
    var line: SIMD4<Float>
    var pageSize: SIMD2<Float>
    var spacing: Float
    var kind: UInt32
    var top: Float = 72
    var lineWidth: Float = 0.75
    var dotRadius: Float = 1
    var pad: Float = 0

    /// Template geometry matches the PencilKit adapter's `TemplatePaths` (rules from y = 72 pt,
    /// 0.75 pt hairlines, 1 pt dots, spacings clamped to ≥ 4 pt).
    init(template: PageTemplate, size: CGSize, paper: RGBA8, line: RGBA8) {
        self.paper = paper.simd
        self.line = line.simd
        pageSize = SIMD2(Float(size.width), Float(size.height))
        switch template {
        case .blank:
            kind = 0
            spacing = 24
        case let .lined(s):
            kind = 1
            spacing = max(s, 4)
        case let .dotted(s):
            kind = 2
            spacing = max(s, 4)
        case let .grid(s):
            kind = 3
            spacing = max(s, 4)
        case .cornell:
            kind = 4
            spacing = 24
        }
    }
}

extension RGBA8 {
    /// Straight-alpha channels in `0...1`.
    var simd: SIMD4<Float> {
        SIMD4(Float(r), Float(g), Float(b), Float(a)) / 255
    }
}
