// The present: the frame drawn into the drawable, cropped + bright Ambilight glow fill (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; float4 box; };
fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    if (c.box.z <= 0.0) {
        return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    }
    float2 b0 = c.box.xy, b1 = c.box.zw, bsz = max(b1 - b0, float2(1e-5));
    if (in.uv.x >= b0.x && in.uv.x <= b1.x && in.uv.y >= b0.y && in.uv.y <= b1.y) {
        float2 guv = (in.uv - b0) / bsz;
        return t.sample(s, clamp(guv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    }
    // Outside game box (bars): sample deeper inside the edge & bloom outward with vivid glow
    float2 clamped = clamp(in.uv, b0, b1);
    float2 guv = (clamped - b0) / bsz;
    float dist = length(in.uv - clamped);
    float2 inward = (clamped - 0.5 * (b0 + b1)) / bsz;
    guv = clamp(guv - inward * 0.16, float2(0.03), float2(0.97));
    float2 base = guv * c.rect.zw + c.rect.xy;
    float2 rad = float2(0.11, 0.11) * c.rect.zw;
    float3 sum = float3(0.0);
    const float2 offs[9] = {
        float2(0.0, 0.0),
        float2(-1.0, 0.0), float2(1.0, 0.0), float2(0.0, -1.0), float2(0.0, 1.0),
        float2(-0.7, -0.7), float2(0.7, -0.7), float2(-0.7, 0.7), float2(0.7, 0.7)
    };
    const float wts[9] = { 0.20, 0.12, 0.12, 0.12, 0.12, 0.08, 0.08, 0.08, 0.08 };
    for (int i = 0; i < 9; i++) {
        float2 suv = clamp(base + offs[i] * rad, c.edge.xy, c.edge.zw);
        sum += t.sample(s, suv).rgb * wts[i];
    }
    // Bright, smooth light-beam falloff from game border outward
    float normDist = clamp(dist * 10.0, 0.0, 1.5);
    float falloff = clamp(exp(-normDist * 1.15) * 0.92 + 0.16, 0.16, 0.95);
    float luma = dot(sum, float3(0.299, 0.587, 0.114));
    float3 vivid = mix(float3(luma), sum, 1.40);
    return float4(clamp(vivid * falloff, 0.0, 1.0), 1.0);
}
