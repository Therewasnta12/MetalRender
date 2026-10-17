package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.buffers.GpuFence;

public final class MetalFence implements GpuFence {
    private final MetalCommandEncoderBackend encoder;
    private final long serial;

    MetalFence(MetalCommandEncoderBackend encoder, long serial) {
        this.encoder = encoder;
        this.serial = serial;
    }

    @Override
    public boolean awaitCompletion(long timeoutNanos) {
        return encoder.awaitSerial(serial, timeoutNanos);
    }

    @Override
    public void close() {
    }
}
