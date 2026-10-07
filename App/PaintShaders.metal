#include <metal_stdlib>
using namespace metal;

struct Dab {
    float2 point;
    float radius;
    float opacity;
    float4 color;
    float hardness;
    float seed;
    uint kind;
    float padding;
};
struct DabVertex {
    float4 position [[position]];
    float2 local;
    float2 pixel;
    float4 color;
    float hardness;
    float seed;
    uint kind [[flat]];
};
vertex DabVertex brushVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                            constant Dab *dabs [[buffer(0)]], constant float2 &size [[buffer(1)]]) {
    const float2 corners[] = {float2(-1,-1), float2(1,-1), float2(-1,1),
                              float2(-1,1), float2(1,-1), float2(1,1)};
    Dab dab = dabs[instanceID];
    float2 local = corners[vertexID];
    float2 pixel = dab.point + local * dab.radius;
    DabVertex out;
    out.position = float4(pixel.x / size.x * 2 - 1, 1 - pixel.y / size.y * 2, 0, 1);
    out.local = local; out.pixel = pixel;
    out.color = float4(dab.color.rgb, dab.color.a * dab.opacity);
    out.hardness = dab.hardness; out.seed = dab.seed; out.kind = dab.kind;
    return out;
}
fragment float4 brushFragment(DabVertex in [[stage_in]], texture2d<float> mask [[texture(0)]],
                               constant uint &hasSelection [[buffer(0)]]) {
    float distance = length(in.local);
    if (distance >= 1) discard_fragment();
    float coverage = 1 - smoothstep(min(in.hardness, 0.999f), 1.0f, distance);
    if (in.kind == 1) {
        float noise = fract(sin(dot(floor(in.pixel), float2(12.9898f, 78.233f)) + in.seed) * 43758.5453f);
        coverage *= 0.5f + noise * 0.5f;
    }
    if (hasSelection) {
        uint2 pixel = uint2(clamp(in.pixel, float2(0), float2(mask.get_width()-1, mask.get_height()-1)));
        coverage *= mask.read(pixel).r;
    }
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}

kernel void clearRegion(texture2d<float, access::write> output [[texture(0)]],
                        constant uint2 &origin [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint2 point = origin + gid;
    if (point.x < output.get_width() && point.y < output.get_height()) output.write(float4(0), point);
}
kernel void compositeLayer(texture2d<float, access::read> destination [[texture(0)]],
                           texture2d<float, access::read> source [[texture(1)]],
                           texture2d<float, access::read> clipBase [[texture(2)]],
                           texture2d<float, access::write> output [[texture(3)]],
                           constant float4 &settings [[buffer(0)]], constant uint2 &origin [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    uint2 point = origin + gid;
    if (point.x >= output.get_width() || point.y >= output.get_height()) return;
    float4 dst = destination.read(point), src = source.read(point) * settings.x;
    if (settings.z > 0.5f) src *= clipBase.read(point).a * settings.w;
    float3 result = src.rgb + dst.rgb * (1 - src.a);
    if (settings.y > 0.5f) {
        float3 s = src.a > 0 ? src.rgb / src.a : float3(0);
        float3 d = dst.a > 0 ? dst.rgb / dst.a : float3(0);
        float3 blend = settings.y < 1.5f ? s * d : 1 - (1 - s) * (1 - d);
        result = src.rgb * (1 - dst.a) + dst.rgb * (1 - src.a) + blend * src.a * dst.a;
    }
    output.write(float4(result, src.a + dst.a * (1 - src.a)), point);
}

struct QuadVertex { float4 position [[position]]; float2 uv; };
struct ViewSettings {
    float2 viewSize;
    float2 canvasSize;
    float2 pan;
    float zoom;
    float angle;
    uint mirrored;
    uint hasSelection;
    uint checkerboard;
    float time;
};
vertex QuadVertex quadVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {float2(-1,1), float2(3,1), float2(-1,-3)};
    const float2 uvs[] = {float2(0,0), float2(2,0), float2(0,2)};
    return {float4(positions[vertexID], 0, 1), uvs[vertexID]};
}
fragment float4 canvasFragment(QuadVertex in [[stage_in]], texture2d<float> canvas [[texture(0)]],
                              texture2d<float> mask [[texture(1)]], constant ViewSettings &view [[buffer(0)]]) {
    float2 relative = (in.uv * view.viewSize - view.viewSize / 2 - view.pan) / view.zoom;
    float c = cos(view.angle), s = sin(view.angle);
    float2 pixel = float2(relative.x * c + relative.y * s, -relative.x * s + relative.y * c);
    if (view.mirrored) pixel.x = -pixel.x;
    pixel += view.canvasSize / 2;
    if (any(pixel < 0) || any(pixel >= view.canvasSize)) return float4(0.13f, 0.14f, 0.17f, 1);
    constexpr sampler sample(filter::linear, address::clamp_to_edge);
    float4 color = canvas.sample(sample, pixel / view.canvasSize);
    float paper = 1;
    if (view.checkerboard) paper = ((int(floor(pixel.x / 12)) + int(floor(pixel.y / 12))) % 2) ? 0.84f : 0.96f;
    float3 display = color.rgb + float3(paper) * (1 - color.a);
    if (view.hasSelection) {
        uint2 p = uint2(pixel);
        float center = mask.read(p).r;
        uint2 right = min(p + uint2(1,0), uint2(view.canvasSize) - 1);
        uint2 bottom = min(p + uint2(0,1), uint2(view.canvasSize) - 1);
        if (center != mask.read(right).r || center != mask.read(bottom).r) {
            float dash = fmod(floor((pixel.x + pixel.y) * view.zoom / 5 + view.time * 2), 2);
            display = float3(dash);
        }
    }
    return float4(display, 1);
}
