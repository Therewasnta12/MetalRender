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
};

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

inline bool terr_unit_keep(UnitRecord unit, float3 cam, float3 rel, constant TerrainCullFrame& f) {
    uint bucket = (unit.meta >> 5) & 7u;
    if (bucket < 6u) {
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
    uint b = unit.box;
    float3 lo = float3(float(b & 31u), float((b >> 5) & 31u), float((b >> 10) & 31u)) - 8.0f;
    float3 hi = float3(float((b >> 15) & 31u), float((b >> 20) & 31u), float((b >> 25) & 31u)) - 8.0f;
    return terr_box_visible(f, rel + lo, rel + hi);
}

constant uint kTerrClassVerts[4] = {24u, 48u, 96u, 192u};

inline uint terr_list_index(uint meta) {
    uint layer = (meta >> 10) & 3u;
    uint n = (meta & 31u) + 1u;
    uint cls = n <= 4u ? 0u : (n <= 8u ? 1u : (n <= 16u ? 2u : 3u));
    return layer < 2u ? layer * 4u + cls : 8u;
}

kernel void terrain_cull_reset(
    device atomic_uint* args [[buffer(0)]],
    device atomic_uint* stats [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid != 0u) {
        return;
    }
    for (uint i = 0u; i < 8u; i++) {
        atomic_store_explicit(&args[i * 4u + 0u], kTerrClassVerts[i & 3u], memory_order_relaxed);
        atomic_store_explicit(&args[i * 4u + 1u], 0u, memory_order_relaxed);
        atomic_store_explicit(&args[i * 4u + 2u], 0u, memory_order_relaxed);
        atomic_store_explicit(&args[i * 4u + 3u], 0u, memory_order_relaxed);
    }
    atomic_store_explicit(&stats[0], 0u, memory_order_relaxed);
    atomic_store_explicit(&stats[1], 0u, memory_order_relaxed);
}

kernel void terrain_cull(
    constant TerrainCullFrame& f [[buffer(0)]],
    device const SectionRecord* sections [[buffer(1)]],
    device const UnitRecord* units [[buffer(2)]],
    device atomic_uint* args [[buffer(3)]],
    device uint2* lists [[buffer(4)]],
    device atomic_uint* stats [[buffer(5)]],
    uint section [[thread_position_in_grid]]
) {
    uint n[8] = {0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    uint quads = 0u;
    SectionRecord sec;
    float3 rel = float3(0.0f);
    float3 cam = float3(0.0f);
    bool visible = false;
    if (section < f.sectionCount) {
        sec = sections[section];
        if ((sec.flags & 3u) == 3u) {
            rel = float3(float(sec.x - f.camBlock.x), float(sec.y - f.camBlock.y), float(sec.z - f.camBlock.z))
                  - f.camFrac.xyz;
            float dx = rel.x + 8.0f;
            float dz = rel.z + 8.0f;
            float lim = f.viewDist + 16.0f;
            visible = (dx * dx + dz * dz <= lim * lim) && terr_box_visible(f, rel, rel + 16.0f);
            cam = -rel;
        }
    }
    if (visible) {
        for (uint u = 0u; u < sec.unitCount; u++) {
            UnitRecord unit = units[sec.firstUnit + u];
            uint li = terr_list_index(unit.meta);
            if (li < 8u && terr_unit_keep(unit, cam, rel, f)) {
                n[li]++;
                quads += (unit.meta & 31u) + 1u;
            }
        }
    }
    uint base[8];
    uint prefix[8];
    uint kept = 0u;
    for (uint i = 0u; i < 8u; i++) {
        uint total = simd_sum(n[i]);
        prefix[i] = simd_prefix_exclusive_sum(n[i]);
        kept += n[i];
        uint b = 0u;
        if (simd_is_first() && total > 0u) {
            b = atomic_fetch_add_explicit(&args[i * 4u + 1u], total, memory_order_relaxed);
        }
        base[i] = simd_broadcast_first(b);
    }
    uint totalQuads = simd_sum(quads);
    uint unitsKept = simd_sum(kept);
    if (simd_is_first() && unitsKept > 0u) {
        atomic_fetch_add_explicit(&stats[0], unitsKept, memory_order_relaxed);
        atomic_fetch_add_explicit(&stats[1], totalQuads, memory_order_relaxed);
    }
    if (!visible || kept == 0u) {
        return;
    }
    uint w[8];
    for (uint i = 0u; i < 8u; i++) {
        w[i] = base[i] + prefix[i];
    }
    for (uint u = 0u; u < sec.unitCount; u++) {
        UnitRecord unit = units[sec.firstUnit + u];
        uint li = terr_list_index(unit.meta);
        if (li >= 8u || !terr_unit_keep(unit, cam, rel, f)) {
            continue;
        }
        if (w[li] < f.listCapacity) {
            lists[li * f.listCapacity + w[li]] = uint2(sec.firstUnit + u, section);
        }
        w[li]++;
    }
}

kernel void terrain_cull_finish(
    device atomic_uint* args [[buffer(0)]],
    constant TerrainCullFrame& f [[buffer(1)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= 8u) {
        return;
    }
    uint count = atomic_load_explicit(&args[tid * 4u + 1u], memory_order_relaxed);
    atomic_store_explicit(&args[tid * 4u + 1u], min(count, f.listCapacity), memory_order_relaxed);
}
