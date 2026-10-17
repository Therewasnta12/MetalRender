package com.pebbles_boon.metalrender.backend.metal;

public final class MetalBackendStats {
    private MetalBackendStats() {
    }

    public static int read(long[] out) {
        long[] values = MetalNative.nBackendStats();
        int n = Math.min(out.length, values.length);
        System.arraycopy(values, 0, out, 0, n);
        return n;
    }
}
