package com.pebbles_boon.metalrender.sodium.mixins;

import com.mojang.blaze3d.systems.GpuBackend;
import com.pebbles_boon.metalrender.backend.metal.MetalGpuBackend;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.ModifyVariable;

@Mixin(Minecraft.class)
public class BackendInstallMixin {
    @ModifyVariable(method = "<init>", at = @At("STORE"), index = 9)
    private GpuBackend[] metalrender$installMetalBackend(GpuBackend[] original) {
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
