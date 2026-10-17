package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.mojang.blaze3d.systems.RenderPass;
import com.mojang.blaze3d.systems.RenderPassBackend;
import com.mojang.blaze3d.textures.GpuSampler;
import com.mojang.blaze3d.textures.GpuTextureView;
import com.mojang.blaze3d.vertex.VertexFormat;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.Supplier;
import org.lwjgl.system.MemoryUtil;

public final class MetalRenderPassBackend implements RenderPassBackend {
    private record Binding(MetalTextureView view, MetalSampler sampler) {
    }

    private final MetalCommandEncoderBackend encoder;
    private final MetalDeviceBackend device;
    final String label;
    final long colorTexture;
    final int colorLevel;
    final int colorFormat;
    final long depthTexture;
    final int depthLevel;
    final int depthFormat;
    final int targetWidth;
    final int targetHeight;
    private final Map<String, GpuBufferSlice> uniforms = new HashMap<>();
    private final Map<String, Binding> samplers = new HashMap<>();
    private MetalCompiledPipeline pipeline;
    private MetalBuffer vertexBuffer;
    private MetalBuffer indexBuffer;
    private VertexFormat.IndexType indexType = VertexFormat.IndexType.INT;
    private boolean scissorEnabled;
    private int scissorX;
    private int scissorY;
    private int scissorWidth;
    private int scissorHeight;
    private int debugGroups;
    private boolean closed;

    MetalRenderPassBackend(MetalCommandEncoderBackend encoder, MetalDeviceBackend device,
            String label, MetalTextureView color, MetalTextureView depth) {
        this.encoder = encoder;
        this.device = device;
        this.label = label;
        if (color != null) {
            this.colorTexture = color.texture().handle();
            this.colorLevel = color.baseMipLevel();
            this.colorFormat = color.texture().pixelFormat();
            this.targetWidth = color.getWidth(0);
            this.targetHeight = color.getHeight(0);
        } else {
            this.colorTexture = 0;
            this.colorLevel = 0;
            this.colorFormat = MetalNative.PIXEL_INVALID;
            this.targetWidth = depth != null ? depth.getWidth(0) : 1;
            this.targetHeight = depth != null ? depth.getHeight(0) : 1;
        }
        if (depth != null) {
            this.depthTexture = depth.texture().handle();
            this.depthLevel = depth.baseMipLevel();
            this.depthFormat = depth.texture().pixelFormat();
        } else {
            this.depthTexture = 0;
            this.depthLevel = 0;
            this.depthFormat = MetalNative.PIXEL_INVALID;
        }
    }

    MetalRenderPassBackend(MetalCommandEncoderBackend encoder, MetalDeviceBackend device,
            String label, MetalTexture color, MetalTexture depth) {
        this.encoder = encoder;
        this.device = device;
        this.label = label;
        this.colorTexture = color != null ? color.handle() : 0;
        this.colorLevel = 0;
        this.colorFormat = color != null ? color.pixelFormat() : MetalNative.PIXEL_INVALID;
        this.depthTexture = depth != null ? depth.handle() : 0;
        this.depthLevel = 0;
        this.depthFormat = depth != null ? depth.pixelFormat() : MetalNative.PIXEL_INVALID;
        MetalTexture size = color != null ? color : depth;
        this.targetWidth = size != null ? size.getWidth(0) : 1;
        this.targetHeight = size != null ? size.getHeight(0) : 1;
    }

    boolean sameTargets(MetalRenderPassBackend other) {
        return other != null && colorTexture == other.colorTexture && colorLevel == other.colorLevel
                && depthTexture == other.depthTexture && depthLevel == other.depthLevel;
    }

    @Override
    public void pushDebugGroup(Supplier<String> label) {
        if (encoder.ensureRenderEncoder(this)) {
            MetalNative.nCtxPushDebugGroup(encoder.ctx(), label.get());
            debugGroups++;
        }
    }

    @Override
    public void popDebugGroup() {
        if (debugGroups > 0 && encoder.isEncoding(this)) {
            MetalNative.nCtxPopDebugGroup(encoder.ctx());
        }
        if (debugGroups > 0) {
            debugGroups--;
        }
    }

    @Override
    public void setPipeline(RenderPipeline pipeline) {
        this.pipeline = device.compiledPipeline(pipeline);
    }

    @Override
    public void bindTexture(String name, GpuTextureView view, GpuSampler sampler) {
        if (view == null || sampler == null) {
            samplers.remove(name);
        } else {
            samplers.put(name, new Binding((MetalTextureView) view, (MetalSampler) sampler));
        }
    }

    @Override
    public void setUniform(String name, GpuBuffer buffer) {
        uniforms.put(name, buffer.slice());
    }

    @Override
    public void setUniform(String name, GpuBufferSlice slice) {
        uniforms.put(name, slice);
    }

    @Override
    public void enableScissor(int x, int y, int width, int height) {
        scissorEnabled = true;
        scissorX = x;
        scissorY = y;
        scissorWidth = width;
        scissorHeight = height;
    }

    @Override
    public void disableScissor() {
        scissorEnabled = false;
    }

    @Override
    public void setVertexBuffer(int slot, GpuBuffer buffer) {
        if (slot != 0) {
            throw new IllegalArgumentException("Vertex buffer slot is out of range: " + slot);
        }
        this.vertexBuffer = (MetalBuffer) buffer;
    }

    @Override
    public void setIndexBuffer(GpuBuffer buffer, VertexFormat.IndexType type) {
        this.indexBuffer = (MetalBuffer) buffer;
        this.indexType = type;
    }

    @Override
    public void drawIndexed(int baseVertex, int firstIndex, int indexCount, int instanceCount) {
        submitDraw(baseVertex, firstIndex, indexCount, indexType, instanceCount);
    }

    @Override
    public <T> void drawMultipleIndexed(Collection<RenderPass.Draw<T>> draws, GpuBuffer fallbackIndexBuffer,
            VertexFormat.IndexType fallbackIndexType, Collection<String> dynamicUniforms, T argument) {
        VertexFormat.IndexType defaultType = fallbackIndexType != null ? fallbackIndexType
                : VertexFormat.IndexType.SHORT;
        for (RenderPass.Draw<T> draw : draws) {
            VertexFormat.IndexType type = draw.indexType() != null ? draw.indexType() : defaultType;
            setIndexBuffer(draw.indexBuffer() != null ? draw.indexBuffer() : fallbackIndexBuffer, type);
            setVertexBuffer(draw.slot(), draw.vertexBuffer());
            if (draw.uniformUploaderConsumer() != null) {
                draw.uniformUploaderConsumer().accept(argument, this::setUniform);
            }
            submitDraw(draw.baseVertex(), draw.firstIndex(), draw.indexCount(), type, 1);
        }
    }

    @Override
    public void draw(int firstVertex, int vertexCount) {
        submitDraw(firstVertex, 0, vertexCount, null, 1);
    }

    private void submitDraw(int baseVertex, int firstIndex, int count, VertexFormat.IndexType type,
            int instances) {
        MetalCompiledPipeline compiled = pipeline;
        if (compiled == null || compiled.drawsNothing() || count <= 0) {
            return;
        }
        RenderPipeline info = compiled.info();
        boolean hasFormat = !info.getVertexFormat().getElements().isEmpty();
        if (hasFormat && (vertexBuffer == null || vertexBuffer.isClosed())) {
            return;
        }
        if (type != null && (indexBuffer == null || indexBuffer.isClosed())) {
            return;
        }
        long pso = compiled.pipelineState(colorFormat, depthFormat);
        if (pso == 0 || !encoder.ensureRenderEncoder(this)) {
            return;
        }
        long ctx = encoder.ctx();
        long serial = encoder.openSerial();
        MetalNative.nCtxSetPipeline(ctx, pso, compiled.depthState(depthTexture != 0),
                compiled.cullMode(), MetalNative.WINDING_CLOCKWISE, compiled.fillMode(),
                compiled.depthBias(), compiled.slopeScale());
        if (scissorEnabled) {
            MetalNative.nCtxSetScissor(ctx, scissorX, scissorY, scissorWidth, scissorHeight);
        } else {
            MetalNative.nCtxSetScissor(ctx, 0, 0, targetWidth, targetHeight);
        }
        for (Map.Entry<String, GpuBufferSlice> entry : uniforms.entrySet()) {
            String name = entry.getKey();
            GpuBufferSlice slice = entry.getValue();
            int texelSlot = MetalBindings.texelBufferSlot(name);
            boolean texel = texelSlot >= 0;
            int slot = texel ? texelSlot : MetalBindings.bufferSlot(name);
            if (slice == null || slot < 0) {
                continue;
            }
            MetalBuffer buffer = (MetalBuffer) slice.buffer();
            if (buffer.isClosed()) {
                continue;
            }
            if (!texel) {
                device.bindings().checkSize(name, slice.length());
            }
            MetalNative.nCtxSetBuffer(ctx, buffer.handle(), slice.offset(), slot);
            buffer.lastUseFrame = serial;
        }
        List<String> samplerNames = info.getSamplers();
        for (int i = 0; i < samplerNames.size(); i++) {
            Binding binding = samplers.get(samplerNames.get(i));
            if (binding == null || binding.view().isClosed() || binding.sampler().isClosed()) {
                continue;
            }
            int slot = binding.view().texture().isCube() ? MetalBindings.CUBE_TEXTURE_SLOT
                    : MetalBindings.textureSlot(samplerNames.get(i), i);
            MetalNative.nCtxSetTexture(ctx, binding.view().handle(), binding.sampler().handle(), slot);
        }
        if (hasFormat) {
            MetalNative.nCtxSetVertexBuffer(ctx, vertexBuffer.handle(), 0, 0);
            vertexBuffer.lastUseFrame = serial;
        }
        if (compiled.triangleFan()) {
            drawFan(ctx, baseVertex, firstIndex, count, type, instances);
            return;
        }
        if (type == null) {
            MetalNative.nCtxDraw(ctx, compiled.primitive(), baseVertex, count, instances);
        } else {
            MetalNative.nCtxDrawIndexed(ctx, compiled.primitive(), count,
                    type == VertexFormat.IndexType.INT, indexBuffer.handle(),
                    (long) firstIndex * type.bytes, instances, baseVertex);
            indexBuffer.lastUseFrame = serial;
        }
    }

    private void drawFan(long ctx, int baseVertex, int firstIndex, int count,
            VertexFormat.IndexType type, int instances) {
        if (count < 3) {
            return;
        }
        int triangles = count - 2;
        MetalStagingRing.Allocation alloc = encoder.stage((long) triangles * 3 * 4, 4);
        long dst = alloc.address();
        if (type == null) {
            for (int i = 1; i <= triangles; i++) {
                MemoryUtil.memPutInt(dst, baseVertex);
                MemoryUtil.memPutInt(dst + 4, baseVertex + i);
                MemoryUtil.memPutInt(dst + 8, baseVertex + i + 1);
                dst += 12;
            }
            MetalNative.nCtxDrawIndexed(ctx, MetalNative.PRIMITIVE_TRIANGLE, triangles * 3, true,
                    alloc.buffer(), alloc.offset(), instances, 0);
            return;
        }
        long src = indexBuffer.contents() + (long) firstIndex * type.bytes;
        boolean wide = type == VertexFormat.IndexType.INT;
        int first = readIndex(src, 0, wide);
        for (int i = 1; i <= triangles; i++) {
            MemoryUtil.memPutInt(dst, first);
            MemoryUtil.memPutInt(dst + 4, readIndex(src, i, wide));
            MemoryUtil.memPutInt(dst + 8, readIndex(src, i + 1, wide));
            dst += 12;
        }
        MetalNative.nCtxDrawIndexed(ctx, MetalNative.PRIMITIVE_TRIANGLE, triangles * 3, true,
                alloc.buffer(), alloc.offset(), instances, baseVertex);
    }

    private static int readIndex(long base, int i, boolean wide) {
        return wide ? MemoryUtil.memGetInt(base + (long) i * 4)
                : Short.toUnsignedInt(MemoryUtil.memGetShort(base + (long) i * 2));
    }

    public long nativeRenderEncoder() {
        if (closed || !encoder.ensureRenderEncoder(this)) {
            return 0;
        }
        return MetalNative.nCtxRenderEncoder(encoder.ctx());
    }

    public int targetWidth() {
        return targetWidth;
    }

    public int targetHeight() {
        return targetHeight;
    }

    public void restoreNativeState() {
        if (encoder.isEncoding(this)) {
            MetalNative.nCtxRestoreViewport(encoder.ctx());
        }
    }

    @Override
    public void close() {
        if (!closed) {
            closed = true;
            while (debugGroups > 0) {
                popDebugGroup();
            }
            encoder.finishRenderPass(this);
        }
    }

    @Override
    public boolean isClosed() {
        return closed;
    }
}
