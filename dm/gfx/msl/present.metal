// The present: the frame drawn into the drawable, cropped + seamless Ambilight glow (nvn_mtl.m present_pipeline)
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
    // Outside game box (bars): start at 1.00 brightness & 0 blur right at the seam so there is zero visible cut line,
    // then progressively bloom blur radius and fade gently outward like YouTube Ambient Mode.
    float2 clamped = clamp(in.uv, b0, b1);
    float2 guv = (clamped - b0) / bsz;
    float dist = length(in.uv - clamped);
    float barH = max(max(b0.y, 1.0 - b1.y), max(b0.x, 1.0 - b1.x));
    float normD = clamp(dist / max(barH, 0.01), 0.0, 1.0);
    float curve = smoothstep(0.0, 1.0, normD);

    // At normD=0, sample right on the exact border pixel; gradually pull inward as normD grows
    float2 inward = (clamped - 0.5 * (b0 + b1)) / bsz;
    guv = clamp(guv - inward * (0.08 * curve), float2(0.001), float2(0.999));
    float2 base = guv * c.rect.zw + c.rect.xy;

    // Progressive 21-tap blur: almost sharp at seam (0.004), very soft outward (0.16)
    float rx = mix(0.004, 0.18, curve) * abs(c.rect.z);
    float ry = mix(0.002, 0.08, curve) * abs(c.rect.w);
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

    // Seamless brightness: 1.00 right at the border (matches game edge 1:1), fading smoothly to soft ambient glow (0.14)
    float falloff = mix(1.00, 0.14, pow(normD, 0.85));
    float luma = dot(sum, float3(0.299, 0.587, 0.114));
    float3 vivid = mix(float3(luma), sum, mix(1.0, 1.30, curve));
    return float4(clamp(vivid * falloff, 0.0, 1.0), 1.0);
}
