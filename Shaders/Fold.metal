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
    float pad;
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

    return float4(c.rgb, 1.0);
}
