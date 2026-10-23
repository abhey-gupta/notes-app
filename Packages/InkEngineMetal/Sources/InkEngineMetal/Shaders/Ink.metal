// Notespace ink shaders (ARCHITECTURE.md §3.3). Struct layouts mirror ShaderTypes.swift.
//
// Color: every target is bgra8Unorm holding sRGB-encoded, premultiplied values (tagged sRGB on the
// layer / CGImage). Blending happens in sRGB space like CoreGraphics and PencilKit, so AA edges have
// the same weight as the reference renders.

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared types

// InkGeometry.StrokeVertex (24 bytes).
struct StrokeVertex {
    float2 position;   // page pt
    float2 edge;       // (along beyond the nearest cap ≥ 0, signed across) pt
    float radius;      // half-width pt
    float arcLength;   // pt along the centerline
};

// Page space → clip space, plus device pixels per page point (for coverage AA).
struct PageTransform {
    float2 scale;
    float2 offset;
    float ppp;
    float pad0;
    float2 pad1;
};

// Per-stroke look, resolved for the paper theme on the CPU.
struct StrokeStyle {
    float4 color;      // straight-alpha sRGB; a = ink alpha × pen opacity
    float softness;    // PenProfile.edgeSoftness
    uint cap;          // 0 round, 1 butt
    uint texture;      // 0 none, 1 ballpoint grain, 2 brush bristles
    float dash;        // dash length pt (0 = solid), overlays only
    float4 start;      // chisel caps: start point, unit tangent into the stroke
    float4 end;        // chisel caps: end point, unit tangent out of the stroke
    float length;      // centerline length pt
    float pad0;
    float2 pad1;
};

// Procedural page template.
struct Background {
    float4 paper;      // straight-alpha sRGB
    float4 line;       // straight-alpha sRGB
    float2 pageSize;   // pt
    float spacing;     // pt
    uint kind;         // 0 blank, 1 lined, 2 dotted, 3 grid, 4 cornell
    float top;         // first rule (lined, cornell)
    float lineWidth;   // pt
    float dotRadius;   // pt
    float pad;
};

constant uint CapButt = 1;
constant uint TextureGrain = 1;
constant uint TextureBristles = 2;

// MARK: - Noise (deterministic, resolution independent: driven by stroke-space coordinates)

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// MARK: - Strokes

struct StrokeOut {
    float4 position [[position]];
    float2 page;
    float2 edge;
    float radius;
    float arcLength;
    uint style [[flat]];
};

static StrokeOut makeStrokeOut(StrokeVertex v, uint style, constant PageTransform &t) {
    StrokeOut o;
    o.position = float4(v.position * t.scale + t.offset, 0, 1);
    o.page = v.position;
    o.edge = v.edge;
    o.radius = v.radius;
    o.arcLength = v.arcLength;
    o.style = style;
    return o;
}

// Whole page in one indexed strip draw: `strokeIndex[vid]` picks the stroke's style.
vertex StrokeOut stroke_vertex_batched(uint vid [[vertex_id]],
                                       const device StrokeVertex *vertices [[buffer(0)]],
                                       const device uint *strokeIndex [[buffer(1)]],
                                       constant PageTransform &t [[buffer(2)]]) {
    return makeStrokeOut(vertices[vid], strokeIndex[vid], t);
}

// One stroke (live, pending, overlays): style 0.
vertex StrokeOut stroke_vertex_single(uint vid [[vertex_id]],
                                      const device StrokeVertex *vertices [[buffer(0)]],
                                      constant PageTransform &t [[buffer(2)]]) {
    return makeStrokeOut(vertices[vid], 0, t);
}

// Signed-distance edge coverage (StrokeVertex doc comment in InkGeometry), no MSAA.
//
// Butt (chisel) caps: every cap is drawn round (InkGeometry's butt formula `max(|y|, max(x, 0) + r)`
// puts the whole body at d = r, i.e. 50 % coverage, since `along` is 0 throughout the body), then the
// two ends are squared off against the stroke's end planes, which also trims the round joins of a
// highlighter's capsule chain that would poke past its ends. Only geometry within ~1.5 radii of arc
// length from an end is clipped, so a stroke curling back past its own start stays whole.
static float strokeCoverage(StrokeOut in, StrokeStyle s, float ppp) {
    float px = 1.0 / ppp;
    float d = length(float2(max(in.edge.x, 0.0), in.edge.y));
    float c;
    if (s.softness > 0.0) {
        // Soft brush edge: fades over the outer `softness` of the radius (never sharper than 1 px),
        // with a ragged, slowly varying edge like a loaded brush, and an ink-like curve that keeps the
        // body dense and only the rim translucent.
        float band = in.radius * s.softness;
        float side = in.edge.y < 0.0 ? 17.0 : 0.0;
        float rag = (valueNoise(float2(in.arcLength * 0.18, side)) - 0.5) * band * 0.6;
        float fade = 1.0 - smoothstep(in.radius - band - 0.5 * px, in.radius + 0.5 * px, d - rag);
        c = pow(fade, 0.6);
    } else {
        c = saturate((in.radius - d) * ppp + 0.5);
    }
    if (s.texture == TextureGrain) {
        // Ballpoint: faint skips along the stroke where the ball runs dry.
        float n = valueNoise(float2(in.arcLength * 0.9, in.edge.y * 3.0));
        c *= 1.0 - 0.16 * smoothstep(0.55, 1.0, n);
    } else if (s.texture == TextureBristles) {
        // Brush: bristle streaks that run along the stroke and scale with its width.
        float across = in.edge.y / max(in.radius, 1e-3);
        float n = valueNoise(float2(in.arcLength * 0.06, across * 6.0));
        c *= 0.8 + 0.2 * n;
    }
    if (s.cap == CapButt) {
        float reach = 1.5 * in.radius + 2.0 * px;
        if (in.arcLength < reach) {
            c *= saturate(dot(in.page - s.start.xy, s.start.zw) * ppp + 0.5);
        }
        if (in.arcLength > s.length - reach) {
            c *= saturate(dot(s.end.xy - in.page, s.end.zw) * ppp + 0.5);
        }
    }
    if (s.dash > 0.0 && fract(in.arcLength / (2.0 * s.dash)) > 0.5) {
        c = 0.0;
    }
    return c;
}

// Ink pass: premultiplied "over".
fragment float4 stroke_fragment(StrokeOut in [[stage_in]],
                                const device StrokeStyle *styles [[buffer(0)]],
                                constant PageTransform &t [[buffer(1)]]) {
    StrokeStyle s = styles[in.style];
    float a = strokeCoverage(in, s, t.ppp) * s.color.a;
    return float4(s.color.rgb * a, a);
}

// Highlighter coverage pass: written with max blending into a cleared coverage target, so a stroke
// crossing itself never darkens (rgb = color, a = coverage × opacity). Strokes sharing one coverage
// pass never overlap (grouped on the CPU), so max never mixes two strokes.
fragment float4 highlight_coverage_fragment(StrokeOut in [[stage_in]],
                                            const device StrokeStyle *styles [[buffer(0)]],
                                            constant PageTransform &t [[buffer(1)]]) {
    StrokeStyle s = styles[in.style];
    return float4(s.color.rgb, strokeCoverage(in, s, t.ppp) * s.color.a);
}

// MARK: - Fullscreen passes (composite blit, highlighter resolve)

struct FullscreenOut {
    float4 position [[position]];
};

vertex FullscreenOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 uv = float2((vid << 1) & 2, vid & 2);
    FullscreenOut o;
    o.position = float4(uv * 2.0 - 1.0, 0, 1);
    return o;
}

// Copies the committed-content composite (same size as the target) into the frame.
fragment float4 composite_fragment(FullscreenOut in [[stage_in]],
                                   texture2d<float, access::read> composite [[texture(0)]]) {
    return composite.read(uint2(in.position.xy));
}

// MARK: - Tiles

// A tile (or thumbnail) region drawn into the frame: destination rect in clip space and the matching
// texture rect (TileQuad in ShaderTypes.swift).
struct TileQuad {
    float4 dst;        // clip x0, y0, x1, y1
    float4 uv;         // u0, v0, u1, v1
};

struct TileOut {
    float4 position [[position]];
    float2 uv;
};

vertex TileOut tile_vertex(uint vid [[vertex_id]], constant TileQuad &q [[buffer(0)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    TileOut o;
    o.position = float4(mix(q.dst.xy, q.dst.zw, corner), 0, 1);
    o.uv = mix(q.uv.xy, q.uv.zw, corner);
    return o;
}

// Bilinear: exact at 1:1 (pixel centers land on texel centers), smooth when a bucket is scaled during
// a pinch or while a fallback shows.
fragment float4 tile_fragment(TileOut in [[stage_in]], texture2d<float> tile [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tile.sample(s, in.uv);
}

// Multiply resolve (light paper): dst × mix(1, color, coverage). Blend: src × dst.
fragment float4 highlight_multiply_fragment(FullscreenOut in [[stage_in]],
                                            texture2d<float, access::read> coverage [[texture(0)]]) {
    float4 c = coverage.read(uint2(in.position.xy));
    return float4(mix(float3(1.0), c.rgb, c.a), 1.0);
}

// Screen resolve (Night paper, where multiply would vanish): dst + c − c × dst. Blend: src × (1 − dst) + dst.
fragment float4 highlight_screen_fragment(FullscreenOut in [[stage_in]],
                                          texture2d<float, access::read> coverage [[texture(0)]]) {
    float4 c = coverage.read(uint2(in.position.xy));
    return float4(c.rgb * c.a, 0.0);
}

// MARK: - Page background

struct BackgroundOut {
    float4 position [[position]];
    float2 page;
};

vertex BackgroundOut background_vertex(uint vid [[vertex_id]],
                                       constant PageTransform &t [[buffer(2)]],
                                       constant Background &b [[buffer(3)]]) {
    float2 corner = float2(vid & 1, vid >> 1);
    BackgroundOut o;
    o.page = corner * b.pageSize;
    o.position = float4(o.page * t.scale + t.offset, 0, 1);
    return o;
}

// Coverage of a line of `width` pt at `dist` pt. Hairlines thinner than a pixel keep a 1 px footprint
// and fade by area, so they neither shimmer nor vanish when zoomed out.
static float lineCoverage(float dist, float width, float ppp) {
    float wpx = width * ppp;
    float footprint = max(wpx, 1.0);
    return saturate(0.5 * footprint - dist * ppp + 0.5) * min(wpx, 1.0);
}

// Coverage of rules at first + k × spacing (k ≥ 0) strictly before `end`.
static float ruleCoverage(float coord, float first, float spacing, float end, float width, float ppp) {
    if (end <= first) {
        return 0.0;
    }
    float last = ceil((end - first) / spacing) - 1.0;
    float k = clamp(round((coord - first) / spacing), 0.0, last);
    return lineCoverage(abs(coord - (first + k * spacing)), width, ppp);
}

static float dotCoverage(float2 p, float spacing, float2 size, float radius, float ppp) {
    float2 last = ceil(size / spacing) - 1.0;
    if (last.x < 1.0 || last.y < 1.0) {
        return 0.0;
    }
    float2 k = clamp(round(p / spacing), float2(1.0), last);
    float d = length(p - k * spacing);
    float rpx = radius * ppp;
    float footprint = max(rpx, 0.7);
    float fade = min(rpx / footprint, 1.0);
    return saturate(footprint - d * ppp + 0.5) * fade * fade;
}

fragment float4 background_fragment(BackgroundOut in [[stage_in]],
                                    constant Background &b [[buffer(0)]],
                                    constant PageTransform &t [[buffer(1)]]) {
    float2 p = in.page;
    float ppp = t.ppp;
    float s = b.spacing;
    float w = b.lineWidth;
    float c = 0.0;
    switch (b.kind) {
    case 1:
        c = ruleCoverage(p.y, b.top, s, b.pageSize.y, w, ppp);
        break;
    case 2:
        c = dotCoverage(p, s, b.pageSize, b.dotRadius, ppp);
        break;
    case 3:
        c = max(ruleCoverage(p.x, s, s, b.pageSize.x, w, ppp), ruleCoverage(p.y, s, s, b.pageSize.y, w, ppp));
        break;
    case 4: {
        // Cue column (29 % width) and summary band (bottom 18 %) over 24 pt rules.
        float summary = round(b.pageSize.y * 0.82);
        float cue = round(b.pageSize.x * 0.29);
        float rules = ruleCoverage(p.y, b.top, 24.0, summary, w, ppp);
        float span = saturate((p.y - (b.top - 24.0)) * ppp + 0.5) * saturate((summary - p.y) * ppp + 0.5);
        float column = lineCoverage(abs(p.x - cue), w, ppp) * span;
        float band = lineCoverage(abs(p.y - summary), w, ppp);
        c = max(max(rules, column), band);
        break;
    }
    default:
        break;
    }
    float a = c * b.line.a;
    return float4(mix(b.paper.rgb, b.line.rgb, a), 1.0);
}
