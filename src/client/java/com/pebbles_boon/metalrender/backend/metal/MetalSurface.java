package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.platform.Window;
import net.minecraft.client.Minecraft;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.glfw.GLFWNativeCocoa;

final class MetalSurface {
    private final long window;
    private long layer;
    private int width;
    private int height;
    private boolean vsync;

    MetalSurface(long window, boolean vsync) {
        this.window = window;
        this.vsync = vsync;
        long nsWindow = GLFWNativeCocoa.glfwGetCocoaWindow(window);
        if (nsWindow == 0) {
            throw new IllegalStateException("GLFW window has no Cocoa window");
        }
        int[] w = new int[1];
        int[] h = new int[1];
        GLFW.glfwGetFramebufferSize(window, w, h);
        this.width = Math.max(1, w[0]);
        this.height = Math.max(1, h[0]);
        this.layer = MetalNative.nSurfaceCreate(nsWindow, width, height, vsync);
        if (layer == 0) {
            throw new IllegalStateException("CAMetalLayer creation failed: " + MetalNative.nLastError());
        }
    }

    long layer() {
        return layer;
    }

    void syncSize() {
        int w;
        int h;
        Minecraft mc = Minecraft.getInstance();
        Window mcWindow = mc != null ? mc.getWindow() : null;
        if (mcWindow != null) {
            w = mcWindow.getWidth();
            h = mcWindow.getHeight();
        } else {
            int[] fw = new int[1];
            int[] fh = new int[1];
            GLFW.glfwGetFramebufferSize(window, fw, fh);
            w = fw[0];
            h = fh[0];
        }
        if (w > 0 && h > 0 && (w != width || h != height)) {
            width = w;
            height = h;
            MetalNative.nSurfaceResize(layer, w, h);
        }
    }

    void setVsync(boolean vsync) {
        if (this.vsync != vsync) {
            this.vsync = vsync;
            MetalNative.nSurfaceSetVsync(layer, vsync);
        }
    }

    void close() {
        if (layer != 0) {
            MetalNative.nRelease(layer);
            layer = 0;
        }
    }
}
