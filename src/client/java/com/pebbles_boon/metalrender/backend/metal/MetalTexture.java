package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.textures.GpuTexture;
import com.mojang.blaze3d.textures.TextureFormat;

public final class MetalTexture extends GpuTexture {
    private long handle;
    private final int pixelFormat;
    private final int textureType;
    private final int layers;

    MetalTexture(MetalDeviceBackend device, int usage, String label, TextureFormat format, int width,
            int height, int depthOrLayers, int mipLevels) {
        super(usage, label, format, width, height, depthOrLayers, mipLevels);
        this.pixelFormat = pixelFormat(format);
        boolean cube = (usage & GpuTexture.USAGE_CUBEMAP_COMPATIBLE) != 0;
        if (cube) {
            this.textureType = MetalNative.TEXTURE_CUBE;
        } else if (depthOrLayers > 1) {
            this.textureType = MetalNative.TEXTURE_2D_ARRAY;
        } else {
            this.textureType = MetalNative.TEXTURE_2D;
        }
        this.layers = cube ? 6 : Math.max(1, depthOrLayers);
        int metalUsage = MetalNative.USAGE_PIXEL_FORMAT_VIEW;
        if ((usage & GpuTexture.USAGE_TEXTURE_BINDING) != 0) {
            metalUsage |= MetalNative.USAGE_SHADER_READ;
        }
        boolean attachment = (usage & GpuTexture.USAGE_RENDER_ATTACHMENT) != 0;
        if (attachment) {
            metalUsage |= MetalNative.USAGE_RENDER_TARGET;
        }
        int storage = attachment ? MetalNative.STORAGE_PRIVATE : MetalNative.STORAGE_SHARED;
        this.handle = MetalNative.nTextureCreate(device.deviceHandle(), textureType, pixelFormat,
                width, height, depthOrLayers, mipLevels, metalUsage, storage);
        if (handle == 0) {
            throw new IllegalStateException("Metal texture creation failed for " + label + ": "
                    + MetalNative.nLastError());
        }
        if (label != null) {
            MetalNative.nSetLabel(handle, label);
        }
    }

    static int pixelFormat(TextureFormat format) {
        return switch (format) {
            case RGBA8 -> MetalNative.PIXEL_RGBA8;
            case RED8 -> MetalNative.PIXEL_R8;
            case RED8I -> MetalNative.PIXEL_R8I;
            case DEPTH32 -> MetalNative.PIXEL_DEPTH32;
        };
    }

    public long handle() {
        return handle;
    }

    int pixelFormat() {
        return pixelFormat;
    }

    int textureType() {
        return textureType;
    }

    int layers() {
        return layers;
    }

    boolean isCube() {
        return textureType == MetalNative.TEXTURE_CUBE;
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
