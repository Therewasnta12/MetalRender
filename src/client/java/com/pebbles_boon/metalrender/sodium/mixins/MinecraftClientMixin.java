package com.pebbles_boon.metalrender.sodium.mixins;

import com.pebbles_boon.metalrender.MetalRenderClient;
import com.pebbles_boon.metalrender.StartupBlocker;
import com.pebbles_boon.metalrender.gui.StartupBlockerOverlay;
import com.pebbles_boon.metalrender.performance.PerformanceController;
import com.pebbles_boon.metalrender.render.MetalWorldRenderer;
import com.pebbles_boon.metalrender.util.MetalLogger;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Overlay;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.main.GameConfig;
import net.minecraft.client.multiplayer.ClientLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import com.pebbles_boon.metalrender.performance.MetalRenderProfiler;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(Minecraft.class)
public class MinecraftClientMixin {
    @Unique
    private static boolean metalrender$qosApplied;
    @Unique
    private static final boolean PROFILE_VANILLA = Boolean.getBoolean("metalrender.profileVanilla");
    @Unique
    private boolean metalrender$levelWasLoaded = false;
    @Unique
    private int metalrender$debugCounter = 0;
    @Unique
    private boolean metalrender$forcingStartupBlocker;

    @Inject(method = "<init>", at = @At("TAIL"))
    private void metalrender$showStartupBlocker(GameConfig gameConfig,
            CallbackInfo ci) {
        if (StartupBlocker.shouldBlockStartup()) {
            metalrender$forceStartupBlocker();
        }
    }

    @Inject(method = "setScreen", at = @At("HEAD"), cancellable = true)
    private void metalrender$keepStartupBlocker(Screen screen, CallbackInfo ci) {
        if (!StartupBlocker.shouldBlockStartup() ||
                metalrender$forcingStartupBlocker) {
            return;
        }
        metalrender$forceStartupBlocker();
        ci.cancel();
    }

    @Inject(method = "setScreenAndRender", at = @At("HEAD"), cancellable = true)
    private void metalrender$keepStartupBlockerVisible(Screen screen,
            CallbackInfo ci) {
        if (!StartupBlocker.shouldBlockStartup() ||
                metalrender$forcingStartupBlocker) {
            return;
        }
        metalrender$forceStartupBlocker();
        ci.cancel();
    }

    @Inject(method = "setOverlay", at = @At("HEAD"), cancellable = true)
    private void metalrender$blockStartupOverlays(Overlay overlay,
            CallbackInfo ci) {
        if (StartupBlocker.shouldBlockStartup() &&
                !metalrender$forcingStartupBlocker &&
                !(overlay instanceof StartupBlockerOverlay)) {
            ci.cancel();
        }
    }

    @Unique
    private void metalrender$forceStartupBlocker() {
        metalrender$forcingStartupBlocker = true;
        try {
            ((Minecraft) (Object) this).setOverlay(new StartupBlockerOverlay());
        } finally {
            metalrender$forcingStartupBlocker = false;
        }
    }

    @Inject(method = "runTick", at = @At("HEAD"))
    private void metalrender$startFrame(boolean tick, CallbackInfo ci) {
        if (StartupBlocker.shouldBlockStartup()) {
            return;
        }
        if (MetalRenderClient.isEnabled()) {
            if (!metalrender$qosApplied && com.pebbles_boon.metalrender.nativebridge.NativeBridge.isLibLoaded()) {
                metalrender$qosApplied = true;
                if (com.pebbles_boon.metalrender.config.MetalRenderConfig.getBool("metalrender.qos", true)) {
                    com.pebbles_boon.metalrender.nativebridge.NativeBridge.nSetThreadQos(0x21);
                }
            }
            PerformanceController.startFrame();
            ClientLevel level = ((Minecraft) (Object) this).level;
            metalrender$debugCounter++;
            if (metalrender$debugCounter % 600 == 1) {
                MetalLogger.deepInfo(
                        "[mcmix] lvl=" +
                                (level != null ? "ok" : "null") +
                                " was=" + metalrender$levelWasLoaded + " wr=" +
                                (MetalRenderClient.getWorldRenderer() != null ? "ok"
                                        : "null"));
            }
            if (level != null && !metalrender$levelWasLoaded) {
                MetalWorldRenderer wr = MetalRenderClient.getWorldRenderer();
                MetalLogger.info("[mcmix] level found wr=" + (wr != null));
                if (wr != null) {
                    try {
                        wr.onWorldLoad();
                        MetalLogger.info("[mcmix] onworldload ok");
                    } catch (Exception e) {
                        MetalLogger.error("[mcmix] onworldload fail", e);
                    }
                }
                metalrender$levelWasLoaded = true;
            } else if (level == null && metalrender$levelWasLoaded) {
                MetalWorldRenderer wr = MetalRenderClient.getWorldRenderer();
                if (wr != null) {
                    wr.onWorldUnload();
                }
                metalrender$levelWasLoaded = false;
            }
            if (level != null) {
                MetalWorldRenderer wr = MetalRenderClient.getWorldRenderer();
                if (wr != null && wr.metalActive()) {
                    wr.prepareMeshes();
                }
            }
        } else if (PROFILE_VANILLA) {
            PerformanceController.startFrame();
        }
    }

    @Inject(method = "runTick", at = @At("TAIL"))
    private void metalrender$endFrame(boolean tick, CallbackInfo ci) {
        if (StartupBlocker.shouldBlockStartup()) {
            return;
        }
        if (MetalRenderClient.isEnabled()) {
            PerformanceController.endFrame();
        } else if (PROFILE_VANILLA) {
            PerformanceController.endFrame();
        }
    }

    @Redirect(method = "renderFrame", at = @At(value = "INVOKE",
            target = "Lcom/mojang/blaze3d/systems/RenderSystem;flipFrame(Lcom/mojang/blaze3d/TracyFrameCapture;)V"))
    private void metalrender$timeFlip(com.mojang.blaze3d.TracyFrameCapture capture) {
        long t0 = System.nanoTime();
        com.mojang.blaze3d.systems.RenderSystem.flipFrame(capture);
        MetalRenderProfiler.getInstance().recordSwap(t0, System.nanoTime());
    }

    @Redirect(method = "renderFrame", at = @At(value = "INVOKE",
            target = "Lnet/minecraft/client/FramerateLimiter;limitDisplayFPS(I)V"))
    private void metalrender$timeLimiter(int fps) {
        long t0 = System.nanoTime();
        net.minecraft.client.FramerateLimiter.limitDisplayFPS(fps);
        MetalRenderProfiler.getInstance().recordLimiter(System.nanoTime() - t0);
    }
}
