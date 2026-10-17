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
            throw new BackendCreationException(error.toString());
        }
        throw new BackendCreationException("Failed to create window for Metal");
    }

    @Override
    public GpuDevice createDevice(long window, ShaderSource shaderSource, GpuDebugOptions debugOptions) {
        try {
            if (MetalRenderConfig.getBool("metalrender.backend.failInit", false)) {
                throw new BackendCreationException("Metal backend disabled by metalrender.backend.failInit");
            }
            GpuDevice device = new GpuDevice(new MetalDeviceBackend(window, shaderSource));
            MetalRenderClient.setBackendMode(true);
            MetalLogger.info("backend ready: Metal (MetalRender)");
            return device;
        } catch (BackendCreationException e) {
            throw MetalGpuBackend.<RuntimeException>sneaky(e);
        } catch (RuntimeException | LinkageError e) {
            throw MetalGpuBackend.<RuntimeException>sneaky(
                    new BackendCreationException("Metal backend failed: " + e));
        }
    }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> T sneaky(Throwable t) throws T {
        throw (T) t;
    }
}
