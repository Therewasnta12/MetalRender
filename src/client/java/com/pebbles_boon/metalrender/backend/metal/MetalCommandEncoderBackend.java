package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.buffers.GpuBuffer;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.buffers.GpuFence;
import com.mojang.blaze3d.platform.NativeImage;
import com.mojang.blaze3d.systems.CommandEncoderBackend;
import com.mojang.blaze3d.systems.GpuQuery;
import com.mojang.blaze3d.systems.RenderPassBackend;
import com.mojang.blaze3d.systems.RenderSystem;
import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.GpuTextureView;
import java.nio.ByteBuffer;
import java.util.OptionalDouble;
import java.util.OptionalInt;
import java.util.function.Supplier;
import net.minecraft.util.ARGB;
import org.lwjgl.system.MemoryUtil;

public final class MetalCommandEncoderBackend implements CommandEncoderBackend {
    private final MetalDeviceBackend device;
    private final long ctx;
    private final MetalStagingRing staging;
    private long openSerial = 1;
    private long completedSerial;
    private long frameIndex = 1;
    private MetalRenderPassBackend currentPass;
    private MetalRenderPassBackend encodingPass;

    MetalCommandEncoderBackend(MetalDeviceBackend device, long ctx) {
        this.device = device;
        this.ctx = ctx;
        this.staging = new MetalStagingRing(device.deviceHandle());
    }

    long ctx() {
        return ctx;
    }

    long openSerial() {
        return openSerial;
    }

    long frameIndex() {
        return frameIndex;
    }

    private long completed() {
        completedSerial = Math.max(completedSerial, MetalNative.nCtxCompleted(ctx));
        return completedSerial;
    }

    MetalStagingRing.Allocation stage(long size, long alignment) {
        return staging.allocate(size, alignment, openSerial, completed());
    }

    private void endEncoder() {
        if (encodingPass != null) {
            MetalNative.nCtxEndEncoder(ctx);
            encodingPass = null;
        }
    }

    boolean isEncoding(MetalRenderPassBackend pass) {
        return encodingPass != null && encodingPass.sameTargets(pass);
    }

    boolean ensureRenderEncoder(MetalRenderPassBackend pass) {
        if (isEncoding(pass)) {
            return true;
        }
        return beginEncoder(pass, false, 0, false, 0.0);
    }

    private boolean beginEncoder(MetalRenderPassBackend pass, boolean clearColor, int argb,
            boolean clearDepth, double depth) {
        encodingPass = null;
        boolean ok = MetalNative.nCtxBeginRender(ctx, pass.label, pass.colorTexture, pass.colorLevel, 0,
                clearColor, ARGB.redFloat(argb), ARGB.greenFloat(argb), ARGB.blueFloat(argb),
                ARGB.alphaFloat(argb), pass.depthTexture, pass.depthLevel, 0, clearDepth, depth);
        if (ok) {
            encodingPass = pass;
        }
        return ok;
    }

    void finishRenderPass(MetalRenderPassBackend pass) {
        if (currentPass == pass) {
            currentPass = null;
        }
    }

    private void flush() {
        endEncoder();
        long serial = MetalNative.nCtxSubmit(ctx, false);
        openSerial = serial + 1;
    }

    boolean awaitSerial(long serial, long timeoutNanos) {
        if (completed() >= serial) {
            return true;
        }
        if (timeoutNanos <= 0) {
            return false;
        }
        if (serial >= openSerial) {
            flush();
        }
        long timeoutMs = Math.max(1L, timeoutNanos / 1_000_000L);
        boolean done = MetalNative.nCtxWait(ctx, serial, timeoutMs);
        completed();
        return done;
    }

    private void waitForUse(long lastUse) {
        if (lastUse <= completed()) {
            return;
        }
        if (lastUse >= openSerial) {
            flush();
        }
        while (!MetalNative.nCtxWait(ctx, lastUse, 1000L)) {
            completed();
        }
        completed();
    }

    void presentFrame() {
        device.surface().syncSize();
        endEncoder();
        long serial = MetalNative.nCtxSubmit(ctx, true);
        openSerial = serial + 1;
        frameIndex++;
        staging.trim(completed());
    }

    void close() {
        endEncoder();
        staging.close();
    }

    @Override
    public RenderPassBackend createRenderPass(Supplier<String> label, GpuTextureView colorView,
            OptionalInt clearColor) {
        return createRenderPass(label, colorView, clearColor, null, OptionalDouble.empty());
    }

    @Override
    public RenderPassBackend createRenderPass(Supplier<String> label, GpuTextureView colorView,
            OptionalInt clearColor, GpuTextureView depthView, OptionalDouble clearDepth) {
        MetalRenderPassBackend pass = new MetalRenderPassBackend(this, device,
                label != null ? label.get() : null, (MetalTextureView) colorView,
                (MetalTextureView) depthView);
        boolean needsClear = clearColor.isPresent() || (depthView != null && clearDepth.isPresent());
        if (needsClear || !isEncoding(pass)) {
            endEncoder();
            beginEncoder(pass, clearColor.isPresent(), clearColor.orElse(0),
                    depthView != null && clearDepth.isPresent(), clearDepth.orElse(1.0));
        } else {
            encodingPass = pass;
        }
        currentPass = pass;
        return pass;
    }

    @Override
    public boolean isInRenderPass() {
        return currentPass != null && !currentPass.isClosed();
    }

    private MetalRenderPassBackend targetPass(String label, GpuTexture color, GpuTexture depth) {
        return new MetalRenderPassBackend(this, device, label, (MetalTexture) color, (MetalTexture) depth);
    }

    @Override
    public void clearColorTexture(GpuTexture texture, int argb) {
        endEncoder();
        MetalRenderPassBackend pass = targetPass("clear color", texture, null);
        beginEncoder(pass, true, argb, false, 0.0);
        endEncoder();
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture color, int argb, GpuTexture depth,
            double clearDepth) {
        endEncoder();
        MetalRenderPassBackend pass = targetPass("clear color and depth", color, depth);
        beginEncoder(pass, true, argb, true, clearDepth);
        endEncoder();
    }

    @Override
    public void clearColorAndDepthTextures(GpuTexture color, int argb, GpuTexture depth,
            double clearDepth, int x, int y, int width, int height) {
        endEncoder();
        MetalRenderPassBackend pass = targetPass("clear region", color, depth);
        if (beginEncoder(pass, false, 0, false, 0.0)) {
            MetalNative.nCtxClearRect(ctx, x, y, width, height, ARGB.redFloat(argb),
                    ARGB.greenFloat(argb), ARGB.blueFloat(argb), ARGB.alphaFloat(argb),
                    (float) clearDepth, depth != null);
        }
        endEncoder();
    }

    @Override
    public void clearDepthTexture(GpuTexture texture, double depth) {
        endEncoder();
        MetalRenderPassBackend pass = targetPass("clear depth", null, texture);
        beginEncoder(pass, false, 0, true, depth);
        endEncoder();
    }

    @Override
    public void writeToBuffer(GpuBufferSlice slice, ByteBuffer data) {
        MetalBuffer buffer = (MetalBuffer) slice.buffer();
        int length = data.remaining();
        if (length <= 0 || buffer.isClosed()) {
            return;
        }
        if (buffer.lastUseFrame <= completed()) {
            buffer.view(slice.offset(), length).put(data.duplicate());
            return;
        }
        MetalStagingRing.Allocation alloc = stage(length, 16);
        MemoryUtil.memByteBuffer(alloc.address(), length).put(data.duplicate());
        endEncoder();
        MetalNative.nCtxCopyBuffer(ctx, alloc.buffer(), alloc.offset(), buffer.handle(), slice.offset(),
                length);
        buffer.lastUseFrame = openSerial;
    }

    @Override
    public GpuBuffer.MappedView mapBuffer(GpuBufferSlice slice, boolean read, boolean write) {
        MetalBuffer buffer = (MetalBuffer) slice.buffer();
        if (read) {
            waitForUse(buffer.lastUseFrame);
        }
        ByteBuffer view = buffer.view(slice.offset(), slice.length());
        return new GpuBuffer.MappedView() {
            @Override
            public ByteBuffer data() {
                return view;
            }

            @Override
            public void close() {
            }
        };
    }

    @Override
    public void copyToBuffer(GpuBufferSlice source, GpuBufferSlice target) {
        MetalBuffer src = (MetalBuffer) source.buffer();
        MetalBuffer dst = (MetalBuffer) target.buffer();
        endEncoder();
        MetalNative.nCtxCopyBuffer(ctx, src.handle(), source.offset(), dst.handle(), target.offset(),
                Math.min(source.length(), target.length()));
        src.lastUseFrame = openSerial;
        dst.lastUseFrame = openSerial;
    }

    @Override
    public void writeToTexture(GpuTexture texture, NativeImage image, int mipLevel, int layer, int dstX,
            int dstY, int width, int height, int srcX, int srcY) {
        int components = image.format().components();
        long src = image.getPointer() + ((long) srcY * image.getWidth() + srcX) * components;
        upload((MetalTexture) texture, src, image.getWidth() * components, image.format(), mipLevel,
                layer, dstX, dstY, width, height);
    }

    @Override
    public void writeToTexture(GpuTexture texture, ByteBuffer data, NativeImage.Format format,
            int mipLevel, int layer, int dstX, int dstY, int width, int height) {
        long src = MemoryUtil.memAddress(data);
        upload((MetalTexture) texture, src, width * format.components(), format, mipLevel, layer,
                dstX, dstY, width, height);
    }

    private void upload(MetalTexture texture, long src, int srcRowBytes, NativeImage.Format format,
            int mipLevel, int layer, int dstX, int dstY, int width, int height) {
        if (width <= 0 || height <= 0 || texture.isClosed()) {
            return;
        }
        int pixelSize = texture.getFormat().pixelSize();
        int rowBytes = width * pixelSize;
        long size = (long) rowBytes * height;
        MetalStagingRing.Allocation alloc = stage(size, 16);
        boolean direct = (format == NativeImage.Format.RGBA && pixelSize == 4)
                || (format == NativeImage.Format.LUMINANCE && pixelSize == 1);
        for (int row = 0; row < height; row++) {
            long s = src + (long) row * srcRowBytes;
            long d = alloc.address() + (long) row * rowBytes;
            if (direct) {
                MemoryUtil.memCopy(s, d, rowBytes);
            } else {
                convertRow(s, d, width, format, pixelSize);
            }
        }
        endEncoder();
        MetalNative.nCtxCopyBufferToTexture(ctx, alloc.buffer(), alloc.offset(), rowBytes,
                (int) size, texture.handle(), layer, mipLevel, dstX, dstY, width, height);
    }

    private static void convertRow(long src, long dst, int width, NativeImage.Format format, int pixelSize) {
        int components = format.components();
        for (int x = 0; x < width; x++) {
            long s = src + (long) x * components;
            long d = dst + (long) x * pixelSize;
            byte r;
            byte g;
            byte b;
            byte a;
            switch (format) {
                case RGBA -> {
                    r = MemoryUtil.memGetByte(s);
                    g = MemoryUtil.memGetByte(s + 1);
                    b = MemoryUtil.memGetByte(s + 2);
                    a = MemoryUtil.memGetByte(s + 3);
                }
                case RGB -> {
                    r = MemoryUtil.memGetByte(s);
                    g = MemoryUtil.memGetByte(s + 1);
                    b = MemoryUtil.memGetByte(s + 2);
                    a = (byte) 0xFF;
                }
                case LUMINANCE_ALPHA -> {
                    r = MemoryUtil.memGetByte(s);
                    g = MemoryUtil.memGetByte(s + 1);
                    b = 0;
                    a = (byte) 0xFF;
                }
                case LUMINANCE -> {
                    r = MemoryUtil.memGetByte(s);
                    g = 0;
                    b = 0;
                    a = (byte) 0xFF;
                }
                default -> throw new IllegalArgumentException("Unsupported image format " + format);
            }
            if (pixelSize == 1) {
                MemoryUtil.memPutByte(d, r);
            } else {
                MemoryUtil.memPutByte(d, r);
                MemoryUtil.memPutByte(d + 1, g);
                MemoryUtil.memPutByte(d + 2, b);
                MemoryUtil.memPutByte(d + 3, a);
            }
        }
    }

    @Override
    public void copyTextureToBuffer(GpuTexture texture, GpuBuffer buffer, long offset, Runnable onDone,
            int mipLevel) {
        copyTextureToBuffer(texture, buffer, offset, onDone, mipLevel, 0, 0, texture.getWidth(mipLevel),
                texture.getHeight(mipLevel));
    }

    @Override
    public void copyTextureToBuffer(GpuTexture texture, GpuBuffer buffer, long offset, Runnable onDone,
            int mipLevel, int x, int y, int width, int height) {
        MetalTexture src = (MetalTexture) texture;
        MetalBuffer dst = (MetalBuffer) buffer;
        int rowBytes = width * texture.getFormat().pixelSize();
        endEncoder();
        MetalNative.nCtxCopyTextureToBuffer(ctx, src.handle(), 0, mipLevel, x, y, width, height,
                dst.handle(), offset, rowBytes, rowBytes * height);
        dst.lastUseFrame = openSerial;
        RenderSystem.queueFencedTask(onDone);
    }

    @Override
    public void copyTextureToTexture(GpuTexture source, GpuTexture target, int mipLevel, int dstX, int dstY,
            int srcX, int srcY, int width, int height) {
        endEncoder();
        MetalNative.nCtxCopyTextureToTexture(ctx, ((MetalTexture) source).handle(), 0, mipLevel, srcX, srcY,
                ((MetalTexture) target).handle(), 0, mipLevel, dstX, dstY, width, height);
    }

    @Override
    public void presentTexture(GpuTextureView view) {
        endEncoder();
        MetalNative.nCtxPresent(ctx, device.surface().layer(), ((MetalTextureView) view).handle());
    }

    @Override
    public GpuFence createFence() {
        return new MetalFence(this, openSerial);
    }

    @Override
    public GpuQuery timerQueryBegin() {
        MetalQuery query = new MetalQuery();
        MetalNative.nCtxQueryBegin(ctx, query.handle());
        return query;
    }

    @Override
    public void timerQueryEnd(GpuQuery query) {
        MetalQuery q = (MetalQuery) query;
        if (q.handle() != 0) {
            MetalNative.nCtxQueryEnd(ctx, q.handle());
        }
    }
}
