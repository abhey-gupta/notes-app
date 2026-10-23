/// Compiled at runtime (`makeLibrary(source:)`) so the spike builds without the Metal Toolchain download.
let inkShaderSource = """
#include <metal_stdlib>
using namespace metal;

// Matches InkGeometry.StrokeVertex (24 bytes).
struct StrokeVertex {
    float2 position;
    float2 edge;
    float radius;
    float arcLength;
};

struct Uniforms {
    float2 viewSize;   // pt
    float ppp;         // pixels per point
    float pad;
    float4 color;      // straight alpha
};

struct VOut {
    float4 position [[position]];
    float2 edge;
    float radius;
};

vertex VOut ink_vertex(uint vid [[vertex_id]],
                       const device StrokeVertex *vertices [[buffer(0)]],
                       constant Uniforms &u [[buffer(1)]]) {
    StrokeVertex v = vertices[vid];
    float2 ndc = v.position / u.viewSize * 2.0 - 1.0;
    VOut out;
    out.position = float4(ndc.x, -ndc.y, 0, 1);
    out.edge = v.edge;
    out.radius = v.radius;
    return out;
}

// Round caps, hard edge (StrokeMesh doc comment).
fragment float4 ink_fragment(VOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float d = length(float2(max(in.edge.x, 0.0), in.edge.y));
    float coverage = saturate((in.radius - d) * u.ppp + 0.5);
    float a = coverage * u.color.a;
    return float4(u.color.rgb * a, a); // premultiplied
}
"""
