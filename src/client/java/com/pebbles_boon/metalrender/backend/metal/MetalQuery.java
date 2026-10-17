package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.systems.GpuQuery;
import java.util.OptionalLong;

public final class MetalQuery implements GpuQuery {
    private long handle;

    MetalQuery() {
        this.handle = MetalNative.nQueryCreate();
    }

    long handle() {
        return handle;
    }

    @Override
    public OptionalLong getValue() {
        if (handle == 0) {
            return OptionalLong.empty();
        }
        long value = MetalNative.nQueryValue(handle);
        return value < 0 ? OptionalLong.empty() : OptionalLong.of(value);
    }

    @Override
    public void close() {
        if (handle != 0) {
            MetalNative.nQueryRelease(handle);
            handle = 0;
        }
    }
}
