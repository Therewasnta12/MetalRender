package com.pebbles_boon.metalrender.backend.metal;

import com.mojang.blaze3d.pipeline.RenderPipeline;
import com.pebbles_boon.metalrender.util.MetalLogger;
import java.lang.reflect.Field;
import java.lang.reflect.Modifier;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import net.minecraft.client.renderer.RenderPipelines;

public final class FamilyTable {
    public enum Family {
        TERRAIN("terrain"),
        ENTITY("entity"),
        TEXT("text"),
        GUI("gui"),
        SKY("sky"),
        CLOUDS_WEATHER("world"),
        LINES("lines"),
        PARTICLE("particle"),
        POST("post"),
        SPRITE_ANIMATION("sprite"),
        UNMAPPED(null);

        private final String functionPrefix;

        Family(String functionPrefix) {
            this.functionPrefix = functionPrefix;
        }

        public boolean implemented() {
            return functionPrefix != null;
        }

        String vertexFunction() {
            return functionPrefix + "_vertex";
        }

        String fragmentFunction() {
            return functionPrefix + "_fragment";
        }
    }

    static final Map<String, Family> BY_VERTEX_SHADER = new HashMap<>();
    static final Map<String, Family> OVERRIDES = new HashMap<>();
    static final Map<String, Integer> VERTEX_VARIANTS = new HashMap<>();
    static final Map<String, Integer> FRAGMENT_VARIANTS = new HashMap<>();

    private static Map<RenderPipeline, String> fieldNames;
    private static boolean coverageLogged;

    static {
        vertex("core/block", Family.TERRAIN);
        vertex("core/terrain", Family.TERRAIN);
        vertex("core/rendertype_crumbling", Family.TERRAIN);
        vertex("core/entity", Family.ENTITY);
        vertex("core/item", Family.ENTITY);
        vertex("core/glint", Family.ENTITY);
        vertex("core/position", Family.ENTITY);
        vertex("core/rendertype_beacon_beam", Family.ENTITY);
        vertex("core/rendertype_end_portal", Family.ENTITY);
        vertex("core/rendertype_entity_shadow", Family.ENTITY);
        vertex("core/rendertype_leash", Family.ENTITY);
        vertex("core/rendertype_lightning", Family.ENTITY);
        vertex("core/rendertype_outline", Family.ENTITY);
        vertex("core/rendertype_water_mask", Family.ENTITY);
        vertex("core/rendertype_text", Family.TEXT);
        vertex("core/rendertype_text_background", Family.TEXT);
        vertex("core/rendertype_text_background_see_through", Family.TEXT);
        vertex("core/rendertype_text_intensity", Family.TEXT);
        vertex("core/rendertype_text_intensity_see_through", Family.TEXT);
        vertex("core/rendertype_text_see_through", Family.TEXT);
        vertex("core/gui", Family.GUI);
        vertex("core/position_tex_color", Family.GUI);
        vertex("core/panorama", Family.GUI);
        vertex("core/sky", Family.SKY);
        vertex("core/stars", Family.SKY);
        vertex("core/position_tex", Family.SKY);
        vertex("core/rendertype_clouds", Family.CLOUDS_WEATHER);
        vertex("core/rendertype_world_border", Family.CLOUDS_WEATHER);
        vertex("core/rendertype_lines", Family.LINES);
        vertex("core/debug_point", Family.LINES);
        vertex("core/position_color", Family.LINES);
        vertex("core/particle", Family.PARTICLE);
        vertex("core/screenquad", Family.POST);
        vertex("post/rotscale", Family.POST);
        vertex("core/animate_sprite", Family.SPRITE_ANIMATION);

        OVERRIDES.put("END_SKY", Family.SKY);
        OVERRIDES.put("SUNRISE_SUNSET", Family.SKY);
        OVERRIDES.put("WEATHER_DEPTH_WRITE", Family.CLOUDS_WEATHER);
        OVERRIDES.put("WEATHER_NO_DEPTH_WRITE", Family.CLOUDS_WEATHER);
        OVERRIDES.put("ANIMATE_SPRITE_BLIT", Family.SPRITE_ANIMATION);
        OVERRIDES.put("ANIMATE_SPRITE_INTERPOLATE", Family.SPRITE_ANIMATION);

        VERTEX_VARIANTS.put("core/gui", 0);
        VERTEX_VARIANTS.put("core/position_tex_color", 1);
        VERTEX_VARIANTS.put("core/panorama", 2);
        VERTEX_VARIANTS.put("core/rendertype_text", 10);
        VERTEX_VARIANTS.put("core/rendertype_text_background", 11);
        VERTEX_VARIANTS.put("core/rendertype_text_intensity", 12);
        VERTEX_VARIANTS.put("core/rendertype_text_see_through", 13);
        VERTEX_VARIANTS.put("core/rendertype_text_background_see_through", 14);
        VERTEX_VARIANTS.put("core/rendertype_text_intensity_see_through", 15);
        VERTEX_VARIANTS.put("core/sky", 20);
        VERTEX_VARIANTS.put("core/stars", 21);
        VERTEX_VARIANTS.put("core/position_tex", 22);
        VERTEX_VARIANTS.put("core/position_color", 23);
        VERTEX_VARIANTS.put("core/rendertype_lines", 30);
        VERTEX_VARIANTS.put("core/debug_point", 31);
        VERTEX_VARIANTS.put("core/screenquad", 40);
        VERTEX_VARIANTS.put("post/rotscale", 41);
        VERTEX_VARIANTS.put("core/animate_sprite", 50);
        VERTEX_VARIANTS.put("core/terrain", 70);
        VERTEX_VARIANTS.put("core/block", 71);
        VERTEX_VARIANTS.put("core/rendertype_crumbling", 72);
        VERTEX_VARIANTS.put("core/entity", 80);
        VERTEX_VARIANTS.put("core/item", 81);
        VERTEX_VARIANTS.put("core/glint", 82);
        VERTEX_VARIANTS.put("core/position", 83);
        VERTEX_VARIANTS.put("core/rendertype_beacon_beam", 84);
        VERTEX_VARIANTS.put("core/rendertype_end_portal", 85);
        VERTEX_VARIANTS.put("core/rendertype_entity_shadow", 86);
        VERTEX_VARIANTS.put("core/rendertype_leash", 87);
        VERTEX_VARIANTS.put("core/rendertype_lightning", 88);
        VERTEX_VARIANTS.put("core/rendertype_outline", 89);
        VERTEX_VARIANTS.put("core/rendertype_water_mask", 90);
        VERTEX_VARIANTS.put("core/particle", 100);
        VERTEX_VARIANTS.put("core/rendertype_clouds", 110);
        VERTEX_VARIANTS.put("core/rendertype_world_border", 111);

        FRAGMENT_VARIANTS.put("core/gui", 0);
        FRAGMENT_VARIANTS.put("core/position_tex_color", 1);
        FRAGMENT_VARIANTS.put("core/panorama", 2);
        FRAGMENT_VARIANTS.put("core/rendertype_text", 10);
        FRAGMENT_VARIANTS.put("core/rendertype_text_background", 11);
        FRAGMENT_VARIANTS.put("core/rendertype_text_intensity", 12);
        FRAGMENT_VARIANTS.put("core/rendertype_text_see_through", 13);
        FRAGMENT_VARIANTS.put("core/rendertype_text_background_see_through", 14);
        FRAGMENT_VARIANTS.put("core/rendertype_text_intensity_see_through", 15);
        FRAGMENT_VARIANTS.put("core/sky", 20);
        FRAGMENT_VARIANTS.put("core/stars", 21);
        FRAGMENT_VARIANTS.put("core/position_tex", 22);
        FRAGMENT_VARIANTS.put("core/position_color", 23);
        FRAGMENT_VARIANTS.put("core/rendertype_lines", 30);
        FRAGMENT_VARIANTS.put("core/blit_screen", 40);
        FRAGMENT_VARIANTS.put("core/lightmap", 41);
        FRAGMENT_VARIANTS.put("post/blit", 42);
        FRAGMENT_VARIANTS.put("post/box_blur", 43);
        FRAGMENT_VARIANTS.put("post/color_convolve", 44);
        FRAGMENT_VARIANTS.put("post/bits", 45);
        FRAGMENT_VARIANTS.put("post/entity_sobel", 46);
        FRAGMENT_VARIANTS.put("post/entity_outline_box_blur", 47);
        FRAGMENT_VARIANTS.put("post/invert", 48);
        FRAGMENT_VARIANTS.put("post/spiderclip", 49);
        FRAGMENT_VARIANTS.put("post/transparency", 50);
        FRAGMENT_VARIANTS.put("core/animate_sprite_blit", 60);
        FRAGMENT_VARIANTS.put("core/animate_sprite_interpolate", 61);
        FRAGMENT_VARIANTS.put("core/terrain", 70);
        FRAGMENT_VARIANTS.put("core/block", 71);
        FRAGMENT_VARIANTS.put("core/rendertype_crumbling", 72);
        FRAGMENT_VARIANTS.put("core/entity", 80);
        FRAGMENT_VARIANTS.put("core/item", 81);
        FRAGMENT_VARIANTS.put("core/glint", 82);
        FRAGMENT_VARIANTS.put("core/position", 83);
        FRAGMENT_VARIANTS.put("core/rendertype_beacon_beam", 84);
        FRAGMENT_VARIANTS.put("core/rendertype_end_portal", 85);
        FRAGMENT_VARIANTS.put("core/rendertype_entity_shadow", 86);
        FRAGMENT_VARIANTS.put("core/rendertype_leash", 87);
        FRAGMENT_VARIANTS.put("core/rendertype_lightning", 88);
        FRAGMENT_VARIANTS.put("core/rendertype_outline", 89);
        FRAGMENT_VARIANTS.put("core/rendertype_water_mask", 90);
        FRAGMENT_VARIANTS.put("core/particle", 100);
        FRAGMENT_VARIANTS.put("core/rendertype_clouds", 110);
        FRAGMENT_VARIANTS.put("core/rendertype_world_border", 111);
    }

    private FamilyTable() {
    }

    private static void vertex(String path, Family family) {
        BY_VERTEX_SHADER.put("minecraft:" + path, family);
    }

    static String shaderKey(net.minecraft.resources.Identifier id) {
        return id == null ? "" : id.getPath();
    }

    public static Family lookup(RenderPipeline pipeline) {
        String field = fieldName(pipeline);
        if (field != null) {
            Family override = OVERRIDES.get(field);
            if (override != null) {
                return override;
            }
        }
        Family family = BY_VERTEX_SHADER.get(String.valueOf(pipeline.getVertexShader()));
        return family != null ? family : Family.UNMAPPED;
    }

    static int vertexVariant(RenderPipeline pipeline) {
        if (!isVanilla(pipeline.getVertexShader())) {
            return -1;
        }
        return VERTEX_VARIANTS.getOrDefault(shaderKey(pipeline.getVertexShader()), -1);
    }

    static int fragmentVariant(RenderPipeline pipeline) {
        if (!isVanilla(pipeline.getFragmentShader())) {
            return -1;
        }
        return FRAGMENT_VARIANTS.getOrDefault(shaderKey(pipeline.getFragmentShader()), -1);
    }

    private static boolean isVanilla(net.minecraft.resources.Identifier id) {
        return id != null && "minecraft".equals(id.getNamespace());
    }

    static boolean drawable(RenderPipeline pipeline, Family family) {
        if (family == Family.UNMAPPED) {
            return false;
        }
        if (!family.implemented()) {
            return true;
        }
        return vertexVariant(pipeline) >= 0 && fragmentVariant(pipeline) >= 0;
    }

    static synchronized String fieldName(RenderPipeline pipeline) {
        if (fieldNames == null) {
            Map<RenderPipeline, String> names = new IdentityHashMap<>();
            for (Field f : RenderPipelines.class.getFields()) {
                if (Modifier.isStatic(f.getModifiers()) && f.getType() == RenderPipeline.class) {
                    try {
                        names.put((RenderPipeline) f.get(null), f.getName());
                    } catch (IllegalAccessException ignored) {
                    }
                }
            }
            fieldNames = names;
        }
        return fieldNames.get(pipeline);
    }

    static synchronized void logCoverage() {
        if (coverageLogged) {
            return;
        }
        coverageLogged = true;
        List<RenderPipeline> pipelines = RenderPipelines.getStaticPipelines();
        int mapped = 0;
        StringBuilder unmapped = new StringBuilder();
        int unmappedCount = 0;
        for (RenderPipeline pipeline : pipelines) {
            Family family = lookup(pipeline);
            if (drawable(pipeline, family)) {
                mapped++;
            } else {
                unmappedCount++;
                String name = fieldName(pipeline);
                unmapped.append(name != null ? name : String.valueOf(pipeline.getLocation())).append(' ');
            }
        }
        MetalLogger.info("family coverage: %d mapped, %d unmapped", mapped, unmappedCount);
        if (unmappedCount > 0) {
            for (String name : unmapped.toString().trim().split(" ")) {
                MetalLogger.info("UNMAPPED %s", name);
            }
        }
    }
}
