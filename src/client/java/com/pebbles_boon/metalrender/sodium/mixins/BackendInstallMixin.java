package com.pebbles_boon.metalrender.sodium.mixins;

import com.mojang.renderpearl.api.device.GpuBackend;
import com.pebbles_boon.metalrender.backend.metal.MetalGpuBackend;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;
import net.minecraft.client.PreferredGraphicsApi;

@Mixin(Minecraft.class)
public class BackendInstallMixin {
    @Redirect(method = "<init>", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/client/PreferredGraphicsApi;getBackendsToTry()[Lcom/mojang/renderpearl/api/device/GpuBackend;"))
    private GpuBackend[] metalrender$installMetalBackend(PreferredGraphicsApi api) {
        GpuBackend[] original = api.getBackendsToTry();
        if ("gl".equals(System.getProperty("metalrender.backend", "metal"))) {
            return original;
        }
        if (!System.getProperty("os.name").contains("Mac") || !System.getProperty("os.arch").equals("aarch64")) {
            return original;
        }
        if (original == null || original.length == 0) {
            return new GpuBackend[] {new MetalGpuBackend()};
        }
        return new GpuBackend[] {new MetalGpuBackend(), original[0]};
    }
}
