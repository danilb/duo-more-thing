#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;        // panel rotated around the hinge, in perspective
    float strength;      // 0 = open, 1 = folded
    float topCurve;      // below 1: the far edge blurs immediately
    float hingeCurve;    // above 1: the hinge edge stays sharp longer
    float shape;         // shape of the gradient along the height
    float maxLod;        // maximum mip = log2(blur radius in px)
    float darkness;      // depth of the shadow
    float darkStart;     // value of n where the shadow begins
    float sideFade;      // how hard the left/right (and far) rims dissolve into the void
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Panel: x in [-0.5, 0.5], y in [0, 1], where y = 0 is the hinge (bottom of the screen).
// Aspect, rotation around the hinge and perspective are baked into mvp.
vertex VSOut fold_vertex(uint vid [[vertex_id]], constant Uniforms &U [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid >> 1) ? 1.0 : 0.0);
    float4 local = float4(corner.x - 0.5, corner.y, 0.0, 1.0);
    VSOut o;
    o.position = U.mvp * local;
    o.uv = float2(corner.x, 1.0 - corner.y);
    return o;
}

fragment float4 fold_fragment(VSOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              constant Uniforms &U [[buffer(0)]])
{
    constexpr sampler smp(address::clamp_to_edge, filter::linear, mip_filter::linear);

    float s = saturate(U.strength);
    float d = 1.0 - in.uv.y;                       // 0 at the hinge, 1 at the far edge

    // Two independent curves: the far edge blurs fast, the hinge edge blurs slowly.
    float nTop   = pow(s, max(U.topCurve, 0.05));
    float nHinge = pow(s, max(U.hingeCurve, 0.05));
    float profile = pow(d, max(U.shape, 0.05));
    float n = saturate(mix(nHinge, nTop, profile));

    float lod = n * U.maxLod;

    // Dissolve the trapezoid silhouette into the surrounding void.
    // Width is 0 at the hinge (the panel still meets the screen edge there)
    // and grows toward the far edge, scaled by fold strength.
    float fade = max(U.sideFade, 0.0) * s;
    float sideWidth = fade * 0.24 * pow(max(d, 0.0), 0.72);
    float topWidth  = fade * 0.11;
    float sideDist  = min(in.uv.x, 1.0 - in.uv.x);
    float topDist   = 1.0 - d;                          // 0 at the far rim
    float sideMask  = sideWidth > 1e-5 ? smoothstep(0.0, sideWidth, sideDist) : 1.0;
    float topMask   = topWidth  > 1e-5 ? smoothstep(0.0, topWidth,  topDist)  : 1.0;
    float rimMask   = pow(saturate(sideMask * topMask), 1.2);
    float rim       = 1.0 - rimMask;
    lod += rim * (3.2 + 2.8 * s);

    // A 5-tap cross at the chosen LOD — kills the blockiness of the mip pyramid.
    float2 texel = exp2(lod) / float2(src.get_width(), src.get_height());
    float4 c  = src.sample(smp, in.uv, level(lod)) * 0.40;
    c += src.sample(smp, in.uv + float2( texel.x, 0.0) * 0.75, level(lod)) * 0.15;
    c += src.sample(smp, in.uv + float2(-texel.x, 0.0) * 0.75, level(lod)) * 0.15;
    c += src.sample(smp, in.uv + float2(0.0,  texel.y) * 0.75, level(lod)) * 0.15;
    c += src.sample(smp, in.uv + float2(0.0, -texel.y) * 0.75, level(lod)) * 0.15;

    // Fade into shadow.
    float dk = saturate((n - U.darkStart) / max(1.0 - U.darkStart, 0.001));
    dk = dk * dk * (3.0 - 2.0 * dk);
    c.rgb *= (1.0 - dk * saturate(U.darkness));
    c.rgb *= rimMask;

    // Premultiplied alpha: rims dissolve into whatever was drawn behind
    // (the room photo, or black if the environment background is off).
    return float4(c.rgb, rimMask);
}

// MARK: - Environment background (the room behind the folding panel)

struct BGUniforms {
    float2 uvScale;   // aspect-fill crop
    float zoom;       // >1 zooms in as the panel recedes
    float darken;
};

vertex VSOut bg_vertex(uint vid [[vertex_id]], constant BGUniforms &U [[buffer(0)]]) {
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid >> 1) ? 1.0 : 0.0);
    VSOut o;
    o.position = float4(corner.x * 2.0 - 1.0, corner.y * 2.0 - 1.0, 0.0, 1.0);
    float2 uv = float2(corner.x, 1.0 - corner.y);
    uv = (uv - 0.5) * U.uvScale / max(U.zoom, 0.001) + 0.5;
    o.uv = uv;
    return o;
}

fragment float4 bg_fragment(VSOut in [[stage_in]],
                            texture2d<float> src [[texture(0)]],
                            constant BGUniforms &U [[buffer(0)]])
{
    constexpr sampler smp(address::clamp_to_edge, filter::linear);
    float4 c = src.sample(smp, in.uv);
    float2 p = in.uv - 0.5;
    float vig = saturate(1.0 - dot(p, p) * 1.25);
    c.rgb *= U.darken * vig;
    return float4(c.rgb, 1.0);
}
