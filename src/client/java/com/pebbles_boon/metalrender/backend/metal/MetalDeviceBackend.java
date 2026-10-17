package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.pipeline.CompiledRenderPipeline;
import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.blaze3d.shaders.ShaderSource;
import com.mojang.blaze3d.systems.BackendCreationException;
import com.mojang.blaze3d.systems.CommandEncoderBackend;
import com.mojang.blaze3d.systems.GpuDeviceBackend;
import com.mojang.blaze3d.textures.AddressMode;
import com.mojang.blaze3d.textures.FilterMode;
import com.mojang.blaze3d.textures.GpuSampler;
import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.GpuTextureView;
import com.mojang.blaze3d.textures.TextureFormat;
import com.pebbles_boon.metalrender.util.MetalLogger;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.OptionalDouble;
import java.util.function.Supplier;
import org.lwjgl.system.MemoryUtil;

public final class MetalDeviceBackend implements GpuDeviceBackend {
    private record SamplerKey(AddressMode u, AddressMode v, FilterMode min, FilterMode mag,
            int maxAnisotropy, OptionalDouble maxLod) {
    }

    private final long device;
    private final long queue;
    private final long library;
    private final long ctx;
    private final String deviceName;
    private final MetalSurface surface;
    private final MetalCommandEncoderBackend encoder;
    private final MetalBindings bindings;
    private final Map<SamplerKey, Long> samplerStates = new HashMap<>();
    private final Map<Integer, Long> depthStates = new HashMap<>();
    private final Map<RenderPipeline, MetalCompiledPipeline> pipelines = new HashMap<>();
    private boolean closed;

    MetalDeviceBackend(long window, ShaderSource shaderSource) throws BackendCreationException {
        try {
            MetalNative.ensureLoaded();
        } catch (Throwable t) {
            throw new BackendCreationException("MetalRender native library unavailable: " + t.getMessage());
        }
        long[] handles = MetalNative.nDeviceCreate();
        if (handles == null || handles[0] == 0 || handles[1] == 0) {
            throw new BackendCreationException("Metal device creation failed: " + MetalNative.nLastError());
        }
        this.device = handles[0];
        this.queue = handles[1];
        MetalNative.nBackendAttach(device, queue);
        this.deviceName = MetalNative.nDeviceName(device);
        this.library = loadLibrary(device);
        if (library == 0) {
            releaseCore(0, 0);
            throw new BackendCreationException("Metal shader library failed: " + MetalNative.nLastError());
        }
        this.ctx = MetalNative.nCtxCreate(device, queue, library);
        if (ctx == 0) {
            releaseCore(library, 0);
            throw new BackendCreationException("Metal command context failed: " + MetalNative.nLastError());
        }
        try {
            this.surface = new MetalSurface(window, false);
        } catch (RuntimeException e) {
            releaseCore(library, ctx);
            throw new BackendCreationException("Metal surface failed: " + e.getMessage());
        }
        this.encoder = new MetalCommandEncoderBackend(this, ctx);
        this.bindings = new MetalBindings(MetalNative.nUniformBlockSizes());
        MetalLogger.info("NativeImage formats: %s", Arrays.toString(NativeImage.Format.values()));
    }

    private void releaseCore(long lib, long context) {
        if (context != 0) {
            MetalNative.nCtxDestroy(context);
        }
        if (lib != 0) {
            MetalNative.nRelease(lib);
        }
        MetalNative.nRelease(queue);
        MetalNative.nRelease(device);
    }

    private static long loadLibrary(long device) {
        try (InputStream in = MetalDeviceBackend.class.getResourceAsStream("/shaders.metallib")) {
            if (in == null) {
                return 0;
            }
            byte[] bytes = in.readAllBytes();
            ByteBuffer data = MemoryUtil.memAlloc(bytes.length);
            try {
                data.put(bytes).flip();
                return MetalNative.nLibraryCreate(device, data, bytes.length);
            } finally {
                MemoryUtil.memFree(data);
            }
        } catch (IOException e) {
            return 0;
        }
    }

    long deviceHandle() {
        return device;
    }

    long libraryHandle() {
        return library;
    }

    MetalSurface surface() {
        return surface;
    }

    MetalBindings bindings() {
        return bindings;
    }

    long depthState(int compare, boolean write) {
        int key = (compare << 1) | (write ? 1 : 0);
        Long cached = depthStates.get(key);
        if (cached == null) {
            cached = MetalNative.nDepthStencilCreate(device, compare, write);
            depthStates.put(key, cached);
        }
        return cached;
    }

    MetalCompiledPipeline compiledPipeline(RenderPipeline pipeline) {
        if (pipeline == null) {
            return null;
        }
        FamilyTable.logCoverage();
        return pipelines.computeIfAbsent(pipeline, p -> new MetalCompiledPipeline(this, p));
    }

    @Override
    public CommandEncoderBackend createCommandEncoder() {
        return encoder;
    }

    @Override
    public GpuSampler createSampler(AddressMode addressModeU, AddressMode addressModeV, FilterMode minFilter,
            FilterMode magFilter, int maxAnisotropy, OptionalDouble maxLod) {
        SamplerKey key = new SamplerKey(addressModeU, addressModeV, minFilter, magFilter, maxAnisotropy,
                maxLod);
        Long handle = samplerStates.get(key);
        if (handle == null) {
            handle = MetalNative.nSamplerCreate(device, address(addressModeU), address(addressModeV),
                    filter(minFilter), filter(magFilter), 2, Math.max(1, maxAnisotropy),
                    maxLod.isPresent() ? (float) maxLod.getAsDouble() : 1000.0f);
            samplerStates.put(key, handle);
        }
        return new MetalSampler(handle, addressModeU, addressModeV, minFilter, magFilter, maxAnisotropy,
                maxLod);
    }

    private static int address(AddressMode mode) {
        return mode == AddressMode.REPEAT ? 2 : 0;
    }

    private static int filter(FilterMode mode) {
        return mode == FilterMode.LINEAR ? 1 : 0;
    }

    @Override
    public GpuTexture createTexture(Supplier<String> label, int usage, TextureFormat format, int width,
            int height, int depthOrLayers, int mipLevels) {
        return createTexture(label != null ? label.get() : null, usage, format, width, height, depthOrLayers,
                mipLevels);
    }

    @Override
    public GpuTexture createTexture(String label, int usage, TextureFormat format, int width, int height,
            int depthOrLayers, int mipLevels) {
        return new MetalTexture(this, usage, label, format, width, height, depthOrLayers, mipLevels);
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture texture) {
        return createTextureView(texture, 0, texture.getMipLevels());
    }

    @Override
    public GpuTextureView createTextureView(GpuTexture texture, int baseMipLevel, int mipLevels) {
        return new MetalTextureView((MetalTexture) texture, baseMipLevel, mipLevels);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, long size) {
        return new MetalBuffer(this, label != null ? label.get() : null, usage, size);
    }

    @Override
    public GpuBuffer createBuffer(Supplier<String> label, int usage, ByteBuffer data) {
        MetalBuffer buffer = new MetalBuffer(this, label != null ? label.get() : null, usage, data.remaining());
        buffer.view(0, data.remaining()).put(data.duplicate());
        return buffer;
    }

    @Override
    public String getImplementationInformation() {
        return "Metal (MetalRender)";
    }

    @Override
    public List<String> getLastDebugMessages() {
        return List.of();
    }

    @Override
    public boolean isDebuggingEnabled() {
        return false;
    }

    @Override
    public String getVendor() {
        return "Apple";
    }

    @Override
    public String getBackendName() {
        return "Metal";
    }

    @Override
    public String getVersion() {
        return "Metal 3";
    }

    @Override
    public String getRenderer() {
        return deviceName;
    }

    @Override
    public int getMaxTextureSize() {
        return 16384;
    }

    @Override
    public int getUniformOffsetAlignment() {
        return 256;
    }

    @Override
    public CompiledRenderPipeline precompilePipeline(RenderPipeline pipeline, ShaderSource shaderSource) {
        return compiledPipeline(pipeline);
    }

    @Override
    public void clearPipelineCache() {
        for (MetalCompiledPipeline pipeline : pipelines.values()) {
            pipeline.release();
        }
        pipelines.clear();
    }

    @Override
    public List<String> getEnabledExtensions() {
        return List.of();
    }

    @Override
    public int getMaxSupportedAnisotropy() {
        return 16;
    }

    @Override
    public void close() {
        if (closed) {
            return;
        }
        closed = true;
        encoder.close();
        clearPipelineCache();
        for (long sampler : samplerStates.values()) {
            MetalNative.nRelease(sampler);
        }
        samplerStates.clear();
        for (long state : depthStates.values()) {
            MetalNative.nRelease(state);
        }
        depthStates.clear();
        surface.close();
        releaseCore(library, ctx);
    }

    @Override
    public void setVsync(boolean vsync) {
        surface.setVsync(vsync);
    }

    @Override
    public void presentFrame() {
        encoder.presentFrame();
    }

    @Override
    public boolean isZZeroToOne() {
        return true;
    }
}
