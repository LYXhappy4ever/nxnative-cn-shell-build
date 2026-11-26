// The present: the frame drawn into the drawable, cropped + two-pass downsampled seamless Ambilight
#include <metal_stdlib>
using namespace metal;
struct V { float4 p [[position]]; float2 uv; };
vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }
struct Crop { float4 rect; float4 edge; float4 box; };

fragment float4 fs_down(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    float2 base = in.uv * c.rect.zw + c.rect.xy;
    float2 step = c.box.xy * float2(abs(c.rect.z), abs(c.rect.w));
    float3 sum = float3(0.0);
    float wsum = 0.0;
    for (int iy = -1; iy <= 1; iy++) {
        float wy = (iy == 0) ? 0.5 : 0.25;
        for (int ix = -1; ix <= 1; ix++) {
            float wx = (ix == 0) ? 0.5 : 0.25;
            float w = wx * wy;
            float2 suv = clamp(base + float2(float(ix) * step.x, float(iy) * step.y), c.edge.xy, c.edge.zw);
            sum += t.sample(s, suv).rgb * w;
            wsum += w;
        }
    }
    return float4(sum / max(wsum, 1e-4), 1.0);
}

fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> ambTex [[texture(1)]], texture2d<float> nearTex [[texture(2)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) {
    if (c.box.z <= 0.0) {
        return t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw));
    }
    float2 b0 = c.box.xy, b1 = c.box.zw, bsz = max(b1 - b0, float2(1e-5));
    float2 clamped = clamp(in.uv, b0, b1);
    float2 guv = (clamped - b0) / bsz;
    bool hasBarY = (b0.y > 0.002) || (b1.y < 0.998);
    bool hasBarX = (b0.x > 0.002) || (b1.x < 0.998);
    if (hasBarY && !hasBarX) {
        bool top = in.uv.y < (b0.y + b1.y) * 0.5;
        float edgeY = top ? 0.0 : 1.0;
        if (in.uv.y >= b0.y && in.uv.y <= b1.y) {
            float2 srcUV = clamp(guv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw);
            float3 game = t.sample(s, srcUV).rgb;
            float innerDistance = top ? guv.y : 1.0 - guv.y;
            constexpr float featherWidth = 0.014;
            if (innerDistance >= featherWidth)
                return float4(game, 1.0);
            // Use the same filtered edge color on both sides of the join.
            float3 edge = nearTex.sample(s, float2(guv.x, edgeY)).rgb;
            return float4(mix(edge, game, smoothstep(0.0, featherWidth, innerDistance)), 1.0);
        }

        float distance = top ? b0.y - in.uv.y : in.uv.y - b1.y;
        float barHeight = top ? b0.y : 1.0 - b1.y;
        float p = saturate(distance / max(barHeight, 1e-5));
        float offset = (top ? 1.0 : -1.0) * distance / bsz.y;
        float3 nearCol = nearTex.sample(s, float2(guv.x, saturate(edgeY + 0.30 * offset))).rgb;
        float3 farCol = ambTex.sample(s, float2(guv.x, saturate(edgeY + 0.12 * offset))).rgb;
        float3 color = mix(nearCol, farCol, smoothstep(0.22, 0.91, p));
        float x = 2.0 * guv.x - 1.0;
        float shade = 1.0 - 0.72 * smoothstep(0.10, 1.0, p);
        float corner = 1.0 - 0.18 * x * x * smoothstep(0.15, 1.0, p);
        return float4(color * shade * corner, 1.0);
    }

    float dist = length(in.uv - clamped);
    float barH = max(max(b0.y, 1.0 - b1.y), max(b0.x, 1.0 - b1.x));
    float normD = clamp(dist / max(barH, 0.01), 0.0, 1.0);

    // Sample the pre-downsampled 16x9 texture with hardware bilinear filtering (zero streaking, zero ghosting)
    float2 auv = clamp(mix(guv, float2(0.5), 0.06 * normD), float2(0.03), float2(0.97));
    float3 glow = ambTex.sample(s, auv).rgb;
    float luma = dot(glow, float3(0.299, 0.587, 0.114));
    float3 vivid = mix(float3(luma), glow, 1.25);
    float falloff = mix(0.90, 0.32, smoothstep(0.0, 1.0, normD));
    float3 barCol = clamp(vivid * falloff, 0.0, 1.0);

    if (in.uv.x >= b0.x && in.uv.x <= b1.x && in.uv.y >= b0.y && in.uv.y <= b1.y) {
        float3 fg = t.sample(s, clamp(guv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)).rgb;
        // Feather only on axes that actually have black bars
        float fy = hasBarY ? smoothstep(0.0, 0.04, min(in.uv.y - b0.y, b1.y - in.uv.y) / bsz.y) : 1.0;
        float fx = hasBarX ? smoothstep(0.0, 0.04, min(in.uv.x - b0.x, b1.x - in.uv.x) / bsz.x) : 1.0;
        float feather = min(fx, fy);
        return float4(mix(barCol, fg, feather), 1.0);
    }
    return float4(barCol, 1.0);
}
