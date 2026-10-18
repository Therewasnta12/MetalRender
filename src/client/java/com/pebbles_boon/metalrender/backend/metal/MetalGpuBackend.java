package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.GLFWErrorCapture;
import com.mojang.blaze3d.shaders.GpuDebugOptions;
import com.mojang.blaze3d.shaders.ShaderSource;
import com.mojang.blaze3d.systems.BackendCreationException;
import com.mojang.blaze3d.systems.GpuBackend;
import com.mojang.blaze3d.systems.GpuDevice;
import com.pebbles_boon.metalrender.MetalRenderClient;
import com.pebbles_boon.metalrender.config.MetalRenderConfig;
import com.pebbles_boon.metalrender.util.MetalLogger;
import org.lwjgl.glfw.GLFW;

public final class MetalGpuBackend implements GpuBackend {
    @Override
    public String getName() {
        return "Metal";
    }

    @Override
    public void setWindowHints() {
        GLFW.glfwWindowHint(GLFW.GLFW_CLIENT_API, GLFW.GLFW_NO_API);
    }

    @Override
    public void handleWindowCreationErrors(GLFWErrorCapture.Error error) throws BackendCreationException {
        if (error != null) {
            throw new BackendCreationException(error.toString(), BackendCreationException.Reason.GLFW_ERROR);
        }
        throw new BackendCreationException("Failed to create window for Metal",
                BackendCreationException.Reason.GLFW_ERROR);
    }

    @Override
    public GpuDevice createDevice(long window, ShaderSource shaderSource, GpuDebugOptions debugOptions,
            Runnable onDeviceClosed) throws BackendCreationException {
        try {
            if (MetalRenderConfig.getBool("metalrender.backend.failInit", false)) {
                throw new BackendCreationException("Metal backend disabled by metalrender.backend.failInit",
                        BackendCreationException.Reason.OTHER);
            }
            GpuDevice device = new GpuDevice(new MetalDeviceBackend(window, shaderSource), onDeviceClosed);
            MetalRenderClient.setBackendMode(true);
            MetalLogger.info("backend ready: Metal (MetalRender)");
            return device;
        } catch (RuntimeException | LinkageError e) {
            throw new BackendCreationException("Metal backend failed: " + e,
                    BackendCreationException.Reason.OTHER);
        }
    }
}
