package com.pebbles_boon.metalrender.sodium.mixins.accessor;

import java.util.List;
import net.minecraft.client.renderer.texture.TextureAtlas;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(TextureAtlas.class)
public interface TextureAtlasAccessor {
    @Accessor("sprites")
    List<TextureAtlasSprite> metalrender$getSprites();
}
