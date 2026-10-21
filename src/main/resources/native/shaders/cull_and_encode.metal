#include <metal_stdlib>
#include "terrain_decode.h"
using namespace metal;
struct CameraUniforms {
    float4x4 viewProjection;
    float4x4 projection;
    float4x4 modelView;
    float4   cameraPosition;
    float4   frustumPlanes[6];
    float2   screenSize;
    float    nearPlane;
    float    farPlane;
    uint     frameIndex;
    uint     hizMipCount;
    uint     totalChunks;
    float    waterFog;
    float    cameraSpeed;
};
struct SubChunkEntry {
    float4   aabbMin;
    float4   aabbMax;
    uint     bufHandleHi;
    uint     bufHandleLo;
    uint     indexCount;
    uint     flags;
};
struct IndirectIndexedArgs {
    uint indexCount;
    uint instanceCount;
    uint indexStart;
    int baseVertex;
    uint baseInstance;
};
struct CullStats {
    atomic_uint visibleCount;
    atomic_uint frustumCulled;
    atomic_uint occlusionCulled;
    atomic_uint distanceCulled;
    atomic_uint totalProcessed;
};
bool isOccludedByHiZ(float3 aabbMin, float3 aabbMax,
                     texture2d<float> hiz,
                     constant CameraUniforms& camera) {
    float2 ssMin = float2(1e10);
    float2 ssMax = float2(-1e10);
    float minDepth = 1.0;
    for (uint i = 0; i < 8; i++) {
        float3 corner = float3(
            (i & 1) ? aabbMax.x : aabbMin.x,
            (i & 2) ? aabbMax.y : aabbMin.y,
            (i & 4) ? aabbMax.z : aabbMin.z
        );
        float4 clip = camera.viewProjection * float4(corner, 1.0);
        if (clip.w <= 0.0) return false;
        float3 ndc = clip.xyz / clip.w;
        float2 ss = (ndc.xy * 0.5 + 0.5) * camera.screenSize;
        ssMin = min(ssMin, ss);
        ssMax = max(ssMax, ss);
        minDepth = min(minDepth, ndc.z);
    }
    ssMin = clamp(ssMin, float2(0), camera.screenSize);
    ssMax = clamp(ssMax, float2(0), camera.screenSize);
    float2 extent = ssMax - ssMin;
    float maxExtent = max(extent.x, extent.y);
    if (maxExtent < 1.0) return false;
    uint mipLevel = uint(ceil(log2(max(maxExtent, 1.0))));
    mipLevel = min(mipLevel, camera.hizMipCount - 1);
    constexpr sampler hizSampler(filter::nearest, address::clamp_to_edge);
    float2 center = (ssMin + ssMax) * 0.5 / camera.screenSize;
    float hizDepth = hiz.sample(hizSampler, center, level(float(mipLevel))).r;
    return (minDepth > hizDepth);
}
bool isInFrustum(float3 minC, float3 maxC, constant float4* planes) {
    for (uint i = 0; i < 4; i++) {
        float4 plane = planes[i];
        float3 pVertex;
        pVertex.x = (plane.x > 0.0) ? maxC.x : minC.x;
        pVertex.y = (plane.y > 0.0) ? maxC.y : minC.y;
        pVertex.z = (plane.z > 0.0) ? maxC.z : minC.z;
        if (dot(plane.xyz, pVertex) + plane.w < 0.0) return false;
    }
    return true;
}
kernel void cull_and_encode(
    device const SubChunkEntry*   chunks       [[buffer(0)]],
    device uint*                  visibleIdx   [[buffer(1)]],
    device atomic_uint*           drawCount    [[buffer(2)]],
    device CullStats*             stats        [[buffer(3)]],
    constant CameraUniforms&      camera       [[buffer(4)]],
    texture2d<float>              hiz          [[texture(0)]],
    device IndirectIndexedArgs*   drawArgs     [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid >= camera.totalChunks) return;
    atomic_fetch_add_explicit(&stats->totalProcessed, 1, memory_order_relaxed);
    drawArgs[gid].indexCount = 0;
    drawArgs[gid].instanceCount = 0;
    drawArgs[gid].indexStart = 0;
    drawArgs[gid].baseVertex = 0;
    drawArgs[gid].baseInstance = gid;
    SubChunkEntry chunk = chunks[gid];
    if (!isInFrustum(chunk.aabbMin.xyz, chunk.aabbMax.xyz, camera.frustumPlanes)) {
        atomic_fetch_add_explicit(&stats->frustumCulled, 1, memory_order_relaxed);
        return;
    }
    if (camera.hizMipCount > 0 && camera.frameIndex > 2) {
        if (isOccludedByHiZ(chunk.aabbMin.xyz, chunk.aabbMax.xyz, hiz, camera)) {
            atomic_fetch_add_explicit(&stats->occlusionCulled, 1, memory_order_relaxed);
            return;
        }
    }
    uint slot = atomic_fetch_add_explicit(drawCount, 1, memory_order_relaxed);
    if (slot < camera.totalChunks) {
        visibleIdx[slot] = gid;
    }
    drawArgs[gid].indexCount = chunk.flags != 0 ? chunk.flags : chunk.indexCount;
    drawArgs[gid].instanceCount = 1;
    drawArgs[gid].indexStart = 0;
    drawArgs[gid].baseVertex = 0;
    drawArgs[gid].baseInstance = gid;
    atomic_fetch_add_explicit(&stats->visibleCount, 1, memory_order_relaxed);
}
kernel void reset_cull_stats(
    device atomic_uint*  drawCount [[buffer(0)]],
    device CullStats*    stats     [[buffer(1)]],
    uint gid [[thread_position_in_grid]]
) {
    if (gid != 0) return;
    atomic_store_explicit(drawCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->visibleCount, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->frustumCulled, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->occlusionCulled, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->distanceCulled, 0, memory_order_relaxed);
    atomic_store_explicit(&stats->totalProcessed, 0, memory_order_relaxed);
}

struct TerrainCullFrame {
    int4   camBlock;
    float4 camFrac;
    float4 planes[4];
    float  viewDist;
    uint   sectionCount;
    uint   listCapacity;
    uint   pad;
    float4x4 prevViewProj;
    float4 prevOffset;
    uint2  hizSize;
    uint   hizMips;
    uint   hizFlags;
};

inline bool terr_hiz_occluded(constant TerrainCullFrame& f, texture2d<float> hiz, float3 lo, float3 hi) {
    if ((f.hizFlags & 1u) == 0u) {
        return false;
    }
    bool rev = (f.hizFlags & 2u) != 0u;
    float2 nmin = float2(1e9f);
    float2 nmax = float2(-1e9f);
    float nearest = rev ? 0.0f : 1.0f;
    for (uint i = 0u; i < 8u; i++) {
        float3 c = float3((i & 1u) ? hi.x : lo.x, (i & 2u) ? hi.y : lo.y, (i & 4u) ? hi.z : lo.z);
        float4 clip = f.prevViewProj * float4(c + f.prevOffset.xyz, 1.0f);
        if (clip.w <= 0.05f) {
            return false;
        }
        float3 ndc = clip.xyz / clip.w;
        nmin = min(nmin, ndc.xy);
        nmax = max(nmax, ndc.xy);
        nearest = rev ? max(nearest, ndc.z) : min(nearest, ndc.z);
    }
    nmin = max(nmin, float2(-1.0f));
    nmax = min(nmax, float2(1.0f));
    if (any(nmin > nmax)) {
        return false;
    }
    float2 full = float2(f.hizSize);
    float2 pmin = float2(nmin.x * 0.5f + 0.5f, 0.5f - nmax.y * 0.5f) * full;
    float2 pmax = float2(nmax.x * 0.5f + 0.5f, 0.5f - nmin.y * 0.5f) * full;
    float extent = max(max(pmax.x - pmin.x, pmax.y - pmin.y), 1.0f);
    uint level = uint(max(ceil(log2(extent)) - 1.0f, 0.0f));
    level = min(level, f.hizMips - 1u);
    float scale = exp2(-(float(level) + 1.0f));
    int2 lim = int2(int(hiz.get_width(level)) - 1, int(hiz.get_height(level)) - 1);
    int2 a = clamp(int2(floor(pmin * scale)), int2(0), lim);
    int2 b = clamp(int2(floor(pmax * scale)), int2(0), lim);
    if (b.x - a.x > 1 || b.y - a.y > 1) {
        return false;
    }
    float far0 = hiz.read(uint2(a), level).r;
    float far1 = hiz.read(uint2(b.x, a.y), level).r;
    float far2 = hiz.read(uint2(a.x, b.y), level).r;
    float far3 = hiz.read(uint2(b), level).r;
    if (rev) {
        return nearest < min(min(far0, far1), min(far2, far3));
    }
    return nearest > max(max(far0, far1), max(far2, far3));
}

inline uint2 terr_hiz_span(uint d, uint dn, uint sn) {
    uint s0 = min(d * 2u, sn - 1u);
    uint s1 = d == dn - 1u ? sn - 1u : min(s0 + 1u, sn - 1u);
    return uint2(s0, s1);
}

kernel void terrain_hiz_from_depth(
    depth2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant uint& reverse [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint dw = dst.get_width();
    uint dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) {
        return;
    }
    uint2 sx = terr_hiz_span(gid.x, dw, src.get_width());
    uint2 sy = terr_hiz_span(gid.y, dh, src.get_height());
    float r = reverse != 0u ? 1.0f : 0.0f;
    for (uint y = sy.x; y <= sy.y; y++) {
        for (uint x = sx.x; x <= sx.y; x++) {
            float d = src.read(uint2(x, y));
            r = reverse != 0u ? min(r, d) : max(r, d);
        }
    }
    dst.write(float4(r), gid);
}

kernel void terrain_hiz_downsample(
    texture2d<float, access::read> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    constant uint& reverse [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint dw = dst.get_width();
    uint dh = dst.get_height();
    if (gid.x >= dw || gid.y >= dh) {
        return;
    }
    uint2 sx = terr_hiz_span(gid.x, dw, src.get_width());
    uint2 sy = terr_hiz_span(gid.y, dh, src.get_height());
    float r = reverse != 0u ? 1.0f : 0.0f;
    for (uint y = sy.x; y <= sy.y; y++) {
        for (uint x = sx.x; x <= sx.y; x++) {
            float d = src.read(uint2(x, y)).r;
            r = reverse != 0u ? min(r, d) : max(r, d);
        }
    }
    dst.write(float4(r), gid);
}

inline bool terr_box_visible(constant TerrainCullFrame& f, float3 lo, float3 hi) {
    for (uint i = 0u; i < 4u; i++) {
        float4 pl = f.planes[i];
        float3 pv = float3(pl.x > 0.0f ? hi.x : lo.x, pl.y > 0.0f ? hi.y : lo.y, pl.z > 0.0f ? hi.z : lo.z);
        if (dot(pl.xyz, pv) + pl.w < -0.5f) {
            return false;
        }
    }
    return true;
}

inline bool terr_unit_facing(UnitRecord unit, float3 cam, constant TerrainCullFrame& f) {
    uint bucket = (unit.meta >> 5) & 7u;
    if ((f.pad & 1u) != 0u && bucket < 6u) {
        float plane = float(unit.plane) / 256.0f;
        uint axis = bucket >> 1;
        float c = axis == 0u ? cam.y : (axis == 1u ? cam.z : cam.x);
        if ((bucket & 1u) != 0u) {
            if (!(c > plane - 1.0f / 64.0f)) {
                return false;
            }
        } else {
            if (!(c < plane + 1.0f / 64.0f)) {
                return false;
            }
        }
    }
    return true;
}

inline bool terr_unit_box_keep(UnitRecord unit, float3 rel, constant TerrainCullFrame& f,
                               texture2d<float> hiz) {
    uint b = unit.box;
    float3 lo = float3(float(b & 31u), float((b >> 5) & 31u), float((b >> 10) & 31u)) - 8.0f;
    float3 hi = float3(float((b >> 15) & 31u), float((b >> 20) & 31u), float((b >> 25) & 31u)) - 8.0f;
    return terr_box_visible(f, rel + lo, rel + hi) && !terr_hiz_occluded(f, hiz, rel + lo, rel + hi);
}

inline bool terr_unit_keep(UnitRecord unit, float3 cam, float3 rel, constant TerrainCullFrame& f,
                           texture2d<float> hiz) {
    return terr_unit_facing(unit, cam, f) && terr_unit_box_keep(unit, rel, f, hiz);
}

constant uint kTerrClassVerts[4] = {24u, 48u, 96u, 192u};
constant uint kTerrLists = 24u;

inline uint terr_list_index(uint meta) {
    uint layer = (meta >> 10) & 3u;
    uint tiled = (meta >> 12) & 1u;
    uint n = (meta & 31u) + 1u;
    uint cls = n <= 4u ? 0u : (n <= 8u ? 1u : (n <= 16u ? 2u : 3u));
    return layer < 3u ? (tiled * 3u + layer) * 4u + cls : kTerrLists;
}

kernel void terrain_cull_reset(
    device atomic_uint* args [[buffer(0)]],
    device atomic_uint* stats [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid != 0u) {
        return;
    }
    for (uint i = 0u; i < kTerrLists; i++) {
        atomic_store_explicit(&args[i * 5u + 0u], kTerrClassVerts[i & 3u], memory_order_relaxed);
        atomic_store_explicit(&args[i * 5u + 1u], 0u, memory_order_relaxed);
        atomic_store_explicit(&args[i * 5u + 2u], 0u, memory_order_relaxed);
        atomic_store_explicit(&args[i * 5u + 3u], 0u, memory_order_relaxed);
        atomic_store_explicit(&args[i * 5u + 4u], 0u, memory_order_relaxed);
    }
    atomic_store_explicit(&stats[0], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[1], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[2], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[3], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[4], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[5], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[6], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[7], 0u, memory_order_relaxed);
}

kernel void terrain_cull(
    constant TerrainCullFrame& f [[buffer(0)]],
    device const SectionRecord* sections [[buffer(1)]],
    device const UnitRecord* units [[buffer(2)]],
    device atomic_uint* args [[buffer(3)]],
    device uint2* lists [[buffer(4)]],
    device atomic_uint* stats [[buffer(5)]],
    texture2d<float> hiz [[texture(0)]],
    uint section [[threadgroup_position_in_grid]],
    uint lane [[thread_index_in_simdgroup]]
) {
    if (section >= f.sectionCount) {
        return;
    }
    SectionRecord sec = sections[section];
    if ((sec.flags & 3u) != 3u) {
        return;
    }
    float3 rel = float3(float(sec.x - f.camBlock.x), float(sec.y - f.camBlock.y), float(sec.z - f.camBlock.z))
                 - f.camFrac.xyz;
    float dx = rel.x + 8.0f;
    float dz = rel.z + 8.0f;
    float lim = f.viewDist + 16.0f;
    if (!((dx * dx + dz * dz <= lim * lim) && terr_box_visible(f, rel, rel + 16.0f))) {
        return;
    }
    if (terr_hiz_occluded(f, hiz, rel, rel + 16.0f)) {
        if (lane == 0u) {
            atomic_fetch_add_explicit(&stats[2], 1u, memory_order_relaxed);
        }
        return;
    }
    float3 cam = -rel;
    uint quads = 0u;
    uint kept = 0u;
    uint lodQuads[3] = {0u, 0u, 0u};
    uint faceInput = 0u;
    uint faceRemoved = 0u;
    for (uint base = 0u; base < sec.unitCount; base += 32u) {
        uint u = base + lane;
        uint li = kTerrLists;
        UnitRecord unit;
        bool keep = false;
        if (u < sec.unitCount) {
            unit = units[sec.firstUnit + u];
            li = terr_list_index(unit.meta);
            if (li < kTerrLists) {
                uint count = (unit.meta & 31u) + 1u;
                faceInput += count;
                if (!terr_unit_facing(unit, cam, f)) {
                    faceRemoved += count;
                } else if (terr_unit_box_keep(unit, rel, f, hiz)) {
                    keep = true;
                    kept++;
                    quads += count;
                    uint tier = (unit.meta >> 8) & 3u;
                    if (tier < 3u) {
                        lodQuads[tier] += count;
                    }
                }
            }
        }
        uint present = simd_or(keep ? (1u << li) : 0u);
        while (present != 0u) {
            uint i = ctz(present);
            present &= present - 1u;
            bool mine = keep && li == i;
            uint total = simd_sum(mine ? 1u : 0u);
            uint prefix = simd_prefix_exclusive_sum(mine ? 1u : 0u);
            uint b = 0u;
            if (lane == 0u) {
                b = atomic_fetch_add_explicit(&args[i * 5u + 1u], total, memory_order_relaxed);
            }
            b = simd_broadcast_first(b);
            if (mine && b + prefix < f.listCapacity) {
                lists[i * f.listCapacity + b + prefix] = uint2(sec.firstUnit + u, section);
            }
        }
    }
    uint totalFaceInput = simd_sum(faceInput);
    uint totalFaceRemoved = simd_sum(faceRemoved);
    uint unitsKept = simd_sum(kept);
    uint totalQuads = simd_sum(quads);
    uint totalLod0 = simd_sum(lodQuads[0]);
    uint totalLod1 = simd_sum(lodQuads[1]);
    uint totalLod2 = simd_sum(lodQuads[2]);
    if (lane == 0u) {
        if (totalFaceInput > 0u) {
            atomic_fetch_add_explicit(&stats[3], totalFaceInput, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[4], totalFaceRemoved, memory_order_relaxed);
        }
        if (unitsKept > 0u) {
            atomic_fetch_add_explicit(&stats[0], unitsKept, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[1], totalQuads, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[5], totalLod0, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[6], totalLod1, memory_order_relaxed);
            atomic_fetch_add_explicit(&stats[7], totalLod2, memory_order_relaxed);
        }
    }
}

kernel void terrain_cull_finish(
    device atomic_uint* args [[buffer(0)]],
    constant TerrainCullFrame& f [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= kTerrLists) {
        return;
    }
    uint count = atomic_load_explicit(&args[tid * 5u + 1u], memory_order_relaxed);
    atomic_store_explicit(&args[tid * 5u + 1u], min(count, f.listCapacity), memory_order_relaxed);
}
