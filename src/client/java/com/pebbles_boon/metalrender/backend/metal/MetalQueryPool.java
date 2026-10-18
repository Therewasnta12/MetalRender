package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.systems.GpuQueryPool;
import java.util.Arrays;
import java.util.OptionalLong;

/** Timestamp queries are not measured by the Metal backend; every slot stays unavailable. */
public final class MetalQueryPool implements GpuQueryPool {
    private final int size;

    MetalQueryPool(int size) {
        this.size = size;
    }

    @Override
    public int size() {
        return size;
    }

    @Override
    public OptionalLong getValue(int index) {
        return OptionalLong.empty();
    }

    @Override
    public OptionalLong[] getValues(int first, int count) {
        OptionalLong[] values = new OptionalLong[count];
        Arrays.fill(values, OptionalLong.empty());
        return values;
    }

    @Override
    public void close() {
    }
}
