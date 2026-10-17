package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.buffers.GpuBuffer;
import java.nio.ByteBuffer;
import org.lwjgl.system.MemoryUtil;

public final class MetalBuffer extends GpuBuffer {
    private long handle;
    private final long contents;
    long lastUseFrame;

    MetalBuffer(MetalDeviceBackend device, String label, int usage, long size) {
        super(usage, size);
        boolean writeCombined = (usage & GpuBuffer.USAGE_MAP_READ) == 0;
        this.handle = MetalNative.nBufferCreate(device.deviceHandle(), size, writeCombined);
        if (handle == 0) {
            throw new IllegalStateException("Metal buffer creation failed for " + label + ": "
                    + MetalNative.nLastError());
        }
        this.contents = MetalNative.nBufferContents(handle);
        if (label != null) {
            MetalNative.nSetLabel(handle, label);
        }
    }

    public long handle() {
        return handle;
    }

    long contents() {
        return contents;
    }

    ByteBuffer view(long offset, long length) {
        return MemoryUtil.memByteBuffer(contents + offset, (int) length);
    }

    @Override
    public boolean isClosed() {
        return handle == 0;
    }

    @Override
    public void close() {
        if (handle != 0) {
            MetalNative.nRelease(handle);
            handle = 0;
        }
    }
}
