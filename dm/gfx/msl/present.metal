// The present: the frame drawn into the drawable, cropped + cinema-grade feathered Ambilight (nvn_mtl.m present_pipeline)
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; float4 box; };

static inline float3 sample_game(texture2d<float> t, sampler s, float2 guv, constant Crop& c) {
    return t.sample(s, clamp(guv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)).rgb;
}

static inline float3 sample_ambient(texture2d<float> t, sampler s, float2 guv, constant Crop& c) {
    // Pull deep enough inward (0.14) and blur very wide so text/UI lines never streak or ghost into the bars
    float2 center = float2(0.5, 0.5);
    float2 deep = mix(guv, center, 0.16);
    float2 base = deep * c.rect.zw + c.rect.xy;
    float rx = 0.24 * abs(c.rect.z);
    float ry = 0.16 * abs(c.rect.w);
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int iy = -2; iy <= 2; iy++) {
        float wy = exp(-0.45 * float(iy * iy));
        for (int ix = -3; ix <= 3; ix++) {
            float wx = exp(-0.25 * float(ix * ix));
            float w = wx * wy;
            float2 suv = clamp(base + float2(float(ix) / 3.0 * rx, float(iy) / 2.0 * ry), c.edge.xy, c.edge.zw);
            sum += t.sample(s, suv).rgb * w;
            wsum += w;
        }
    }
    sum /= max(wsum, 1e-4);
    float luma = dot(sum, float3(0.299, 0.587, 0.114));
    return mix(float3(luma), sum, 1.35);
}

fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    if (c.box.z <= 0.0) {
        return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    }
    float2 b0 = c.box.xy, b1 = c.box.zw, bsz = max(b1 - b0, float2(1e-5));
    float2 clamped = clamp(in.uv, b0, b1);
    float2 guv = (clamped - b0) / bsz;
    float dist = length(in.uv - clamped);
    float barH = max(max(b0.y, 1.0 - b1.y), max(b0.x, 1.0 - b1.x));
    float normD = clamp(dist / max(barH, 0.01), 0.0, 1.0);

    // Pure ambient glow color (soft, rich, zero sharp lines or text ghosting)
    float3 glow = sample_ambient(t, s, guv, c);
    float glowFade = mix(0.55, 0.12, smoothstep(0.0, 1.0, normD));
    float3 barCol = glow * glowFade;

    if (in.uv.x >= b0.x && in.uv.x <= b1.x && in.uv.y >= b0.y && in.uv.y <= b1.y) {
        float3 fg = sample_game(t, s, guv, c);
        // Feather the outer 2.5% of the game edge smoothly into the ambient glow to erase any hard cut line
        float edgeY = min(in.uv.y - b0.y, b1.y - in.uv.y) / max(bsz.y, 1e-4);
        float edgeX = min(in.uv.x - b0.x, b1.x - in.uv.x) / max(bsz.x, 1e-4);
        float minEdge = min(edgeX, edgeY);
        float feather = smoothstep(0.0, 0.022, minEdge);
        return float4(clamp(mix(barCol, fg, feather), 0.0, 1.0), 1.0);
    }
    return float4(clamp(barCol, 0.0, 1.0), 1.0);
}
