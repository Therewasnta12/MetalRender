package com.pebbles_boon.metalrender.sodium.mixins.accessor;

import com.mojang.renderpearl.api.commands.RenderPass;
import com.mojang.renderpearl.backend.api.RenderPassBackend;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(com.mojang.renderpearl.frontend.FrontendRenderPass.class)
public interface RenderPassAccessor {
    @Accessor("backend")
    RenderPassBackend metalrender$getBackend();
}
