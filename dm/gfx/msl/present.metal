// The present: the frame drawn into the drawable, cropped + smooth wide-blur Ambilight glow (nvn_mtl.m present_pipeline)
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
    // Outside game box (bars): anchor right at the touching border, blur wide horizontally & softly inward to avoid any vertical streaking
    float2 clamped = clamp(in.uv, b0, b1);
    float2 guv = (clamped - b0) / bsz;
    float dist = length(in.uv - clamped);
    float barH = max(max(b0.y, 1.0 - b1.y), max(b0.x, 1.0 - b1.x));
    float normD = clamp(dist / max(barH, 0.01), 0.0, 1.0);
    // Step slightly inward progressively as we move further into the bar, keeping exact edge color right at the seam
    float2 inward = (clamped - 0.5 * (b0 + b1)) / bsz;
    guv = clamp(guv - inward * (0.015 + 0.07 * normD), float2(0.005), float2(0.995));
    float2 base = guv * c.rect.zw + c.rect.xy;

    // Wide 2D Gaussian-like 21-tap blur (stronger horizontally to completely eliminate vertical line streaks)
    float rx = (0.04 + 0.14 * normD) * abs(c.rect.z);
    float ry = (0.015 + 0.06 * normD) * abs(c.rect.w);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int iy = -1; iy <= 1; iy++) {
        float wy = (iy == 0) ? 0.5 : 0.25;
        for (int ix = -3; ix <= 3; ix++) {
            float wx = exp(-0.22 * float(ix * ix));
            float w = wx * wy;
            float2 suv = clamp(base + float2(float(ix) / 3.0 * rx, float(iy) * ry), c.edge.xy, c.edge.zw);
            sum += t.sample(s, suv).rgb * w;
            wsum += w;
        }
    }
    sum /= max(wsum, 1e-4);

    // Smooth falloff: bright & seamless at the border (0.85), fading gently to a soft glow (0.12) at the screen edge
    float falloff = mix(0.85, 0.12, smoothstep(0.0, 1.0, normD));
    float luma = dot(sum, float3(0.299, 0.587, 0.114));
    float3 vivid = mix(float3(luma), sum, 1.28);
    return float4(clamp(vivid * falloff, 0.0, 1.0), 1.0);
}
