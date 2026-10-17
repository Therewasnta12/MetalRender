package com.pebbles_boon.metalrender.sodium.mixins;

import com.pebbles_boon.metalrender.MetalRenderClient;
import com.pebbles_boon.metalrender.render.MetalWorldRenderer;
import net.minecraft.client.renderer.SectionBufferBuilderPack;
import net.minecraft.client.renderer.chunk.SectionRenderDispatcher;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import com.pebbles_boon.metalrender.config.MetalRenderConfig;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import net.minecraft.client.renderer.chunk.RenderRegionCache;
import com.pebbles_boon.metalrender.performance.MetalRenderProfiler;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

@Mixin(targets = { "net.minecraft.client.renderer.chunk.SectionRenderDispatcher$" +
        "RenderSection$RebuildTask",
        "net.minecraft.client.renderer.chunk.SectionRenderDispatcher$" +
                "RenderSection$ResortTransparencyTask",
        "net.minecraft.client.renderer.chunk.SectionRenderDispatcher$RenderSection" }, remap = false)
public abstract class VanillaSectionCompileTaskMixin {
    @Unique
    private long metalrender$compileStartNs;

    @Inject(method = {"rebuildSectionAsync", "compileSync"}, at = @At("HEAD"), cancellable = true, require = 0)
    private void metalrender$startCompile(RenderRegionCache cache, CallbackInfo ci) {
        metalrender$compileStartNs = System.nanoTime();
        if (metalrender$skipScheduling()) {
            MetalRenderProfiler.getInstance().recordVanillaCompile(System.nanoTime() - metalrender$compileStartNs);
            ci.cancel();
        }
    }

    @Inject(method = {"rebuildSectionAsync", "compileSync"}, at = @At("RETURN"), require = 0)
    private void metalrender$endCompile(RenderRegionCache cache, CallbackInfo ci) {
        MetalRenderProfiler.getInstance().recordVanillaCompile(System.nanoTime() - metalrender$compileStartNs);
    }

    @Unique
    private static boolean metalrender$skipScheduling() {
        MetalWorldRenderer renderer = MetalRenderClient.getWorldRenderer();
        return MetalRenderConfig.getBool("metalrender.cancelVanillaCompile", true)
                && MetalRenderClient.isEnabled() && renderer != null && renderer.metalActive();
    }

    @Inject(method = "resortTransparency", at = @At("HEAD"), cancellable = true, require = 0)
    private void metalrender$skipResort(SectionRenderDispatcher dispatcher, CallbackInfo ci) {
        if (metalrender$skipScheduling()) ci.cancel();
    }

    @Inject(method = "doTask", at = @At("HEAD"), cancellable = true, require = 0)
    private void metalrender$cancelVanillaSectionCompile(
            SectionBufferBuilderPack buffers,
            CallbackInfoReturnable<SectionRenderDispatcher.RenderSection.CompileTask.SectionTaskResult> cir) {
        if (!MetalRenderClient.isEnabled()) {
            return;
        }
        MetalWorldRenderer worldRenderer = MetalRenderClient.getWorldRenderer();
        if (worldRenderer == null || !worldRenderer.metalActive()) {
            return;
        }
        cir.setReturnValue(SectionRenderDispatcher.RenderSection.CompileTask.SectionTaskResult.CANCELLED);
    }
}