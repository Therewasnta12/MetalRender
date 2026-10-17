#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <jni.h>
#include <string>
#include <time.h>
#include <unordered_map>

#include "shaders/families_layout.h"

extern id<MTLDevice> g_device;

#define MR_JNI(name) Java_com_pebbles_1boon_metalrender_backend_metal_MetalNative_##name

static std::string g_backendLastError;

static void mr_set_error(NSError *error, const char *what) {
  g_backendLastError = what;
  if (error) {
    g_backendLastError += ": ";
    g_backendLastError += [[error localizedDescription] UTF8String];
  }
}

static std::string mr_jstring(JNIEnv *env, jstring s) {
  if (!s)
    return std::string();
  const char *chars = env->GetStringUTFChars(s, nullptr);
  std::string out(chars ? chars : "");
  if (chars)
    env->ReleaseStringUTFChars(s, chars);
  return out;
}

struct MRQuery {
  std::atomic<int> refs{1};
  std::atomic<uint64_t> startNs{0};
  std::atomic<uint64_t> endNs{0};
  std::atomic<bool> started{false};
  std::atomic<bool> ended{false};
};

static void mr_query_release(MRQuery *q) {
  if (q->refs.fetch_sub(1) == 1)
    delete q;
}

struct MRContext {
  id<MTLDevice> device = nil;
  id<MTLCommandQueue> queue = nil;
  id<MTLLibrary> library = nil;
  id<MTLSharedEvent> event = nil;
  id<MTLCommandBuffer> cmd = nil;
  id<MTLRenderCommandEncoder> render = nil;
  id<MTLBlitCommandEncoder> blit = nil;
  dispatch_semaphore_t frameSemaphore = nullptr;
  uint64_t openSerial = 1;
  int targetWidth = 0;
  int targetHeight = 0;
  MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
  MTLPixelFormat depthFormat = MTLPixelFormatInvalid;
  id<MTLRenderPipelineState> presentPipeline = nil;
  std::unordered_map<uint64_t, id<MTLRenderPipelineState>> clearPipelines;
  id<MTLDepthStencilState> clearDepthWrite = nil;
  id<MTLDepthStencilState> clearDepthKeep = nil;
};

static id<MTLCommandBuffer> mr_cmd(MRContext *ctx) {
  if (!ctx->cmd) {
    ctx->cmd = [[ctx->queue commandBuffer] retain];
  }
  return ctx->cmd;
}

static void mr_end_encoders(MRContext *ctx) {
  if (ctx->render) {
    [ctx->render endEncoding];
    [ctx->render release];
    ctx->render = nil;
  }
  if (ctx->blit) {
    [ctx->blit endEncoding];
    [ctx->blit release];
    ctx->blit = nil;
  }
}

static id<MTLBlitCommandEncoder> mr_blit(MRContext *ctx) {
  if (ctx->render) {
    [ctx->render endEncoding];
    [ctx->render release];
    ctx->render = nil;
  }
  if (!ctx->blit) {
    ctx->blit = [[mr_cmd(ctx) blitCommandEncoder] retain];
  }
  return ctx->blit;
}

static uint64_t mr_now_ns() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

extern "C" JNIEXPORT jlongArray JNICALL MR_JNI(nDeviceCreate)(JNIEnv *env, jclass) {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      g_backendLastError = "MTLCreateSystemDefaultDevice returned nil";
      return nullptr;
    }
    id<MTLCommandQueue> queue = [device newCommandQueueWithMaxCommandBufferCount:64];
    if (!queue) {
      [device release];
      g_backendLastError = "newCommandQueue returned nil";
      return nullptr;
    }
    jlongArray out = env->NewLongArray(2);
    jlong values[2] = {(jlong)(uintptr_t)device, (jlong)(uintptr_t)queue};
    env->SetLongArrayRegion(out, 0, 2, values);
    return out;
  }
}

extern "C" JNIEXPORT jstring JNICALL MR_JNI(nDeviceName)(JNIEnv *env, jclass, jlong device) {
  id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
  return env->NewStringUTF(d ? [[d name] UTF8String] : "unknown");
}

extern "C" JNIEXPORT jstring JNICALL MR_JNI(nLastError)(JNIEnv *env, jclass) {
  return env->NewStringUTF(g_backendLastError.c_str());
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nRelease)(JNIEnv *, jclass, jlong object) {
  if (object) {
    id obj = (id)(uintptr_t)object;
    [obj release];
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nLibraryCreate)(JNIEnv *env, jclass, jlong device, jobject data,
                                                          jint length) {
  @autoreleasepool {
    id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
    void *bytes = env->GetDirectBufferAddress(data);
    if (!d || !bytes || length <= 0) {
      g_backendLastError = "invalid metallib data";
      return 0;
    }
    dispatch_data_t dd = dispatch_data_create(bytes, (size_t)length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> lib = [d newLibraryWithData:dd error:&error];
    dispatch_release(dd);
    if (!lib) {
      mr_set_error(error, "newLibraryWithData failed");
      return 0;
    }
    id<MTLFunction> probe = [lib newFunctionWithName:@"gui_vertex"];
    if (!probe) {
      [lib release];
      g_backendLastError = "metallib has no family functions";
      return 0;
    }
    [probe release];
    return (jlong)(uintptr_t)lib;
  }
}

extern "C" JNIEXPORT jintArray JNICALL MR_JNI(nUniformBlockSizes)(JNIEnv *env, jclass) {
  jint sizes[MR_BLOCK_COUNT];
  sizes[MR_BLOCK_PROJECTION] = sizeof(MRProjection);
  sizes[MR_BLOCK_DYNAMIC_TRANSFORMS] = sizeof(MRDynamicTransforms);
  sizes[MR_BLOCK_FOG] = sizeof(MRFog);
  sizes[MR_BLOCK_GLOBALS] = sizeof(MRGlobals);
  sizes[MR_BLOCK_LIGHTING] = sizeof(MRLighting);
  sizes[MR_BLOCK_CHUNK_SECTION] = sizeof(MRChunkSection);
  sizes[MR_BLOCK_LIGHTMAP_INFO] = sizeof(MRLightmapInfo);
  sizes[MR_BLOCK_SPRITE_ANIMATION_INFO] = sizeof(MRSpriteAnimationInfo);
  sizes[MR_BLOCK_SAMPLER_INFO] = sizeof(MRSamplerInfo);
  sizes[MR_BLOCK_BLUR_CONFIG] = sizeof(MRBlurConfig);
  sizes[MR_BLOCK_BLIT_CONFIG] = sizeof(MRBlitConfig);
  sizes[MR_BLOCK_COLOR_CONFIG] = sizeof(MRColorConfig);
  sizes[MR_BLOCK_BITS_CONFIG] = sizeof(MRBitsConfig);
  sizes[MR_BLOCK_INVERT_CONFIG] = sizeof(MRInvertConfig);
  sizes[MR_BLOCK_ROTSCALE_CONFIG] = sizeof(MRRotScaleConfig);
  sizes[MR_BLOCK_SPIDER_CONFIG] = sizeof(MRSpiderConfig);
  sizes[MR_BLOCK_CLOUD_INFO] = sizeof(MRCloudInfo);
  jintArray out = env->NewIntArray(MR_BLOCK_COUNT);
  env->SetIntArrayRegion(out, 0, MR_BLOCK_COUNT, sizes);
  return out;
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nSurfaceCreate)(JNIEnv *, jclass, jlong nsWindow, jint width,
                                                          jint height, jboolean vsync) {
  @autoreleasepool {
    NSWindow *window = (NSWindow *)(uintptr_t)nsWindow;
    if (!window || !g_device) {
      g_backendLastError = "no window or device for surface";
      return 0;
    }
    NSView *view = [window contentView];
    if (!view) {
      g_backendLastError = "window has no content view";
      return 0;
    }
    view.wantsLayer = YES;
    CAMetalLayer *layer = [[CAMetalLayer alloc] init];
    layer.device = g_device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.maximumDrawableCount = 3;
    layer.displaySyncEnabled = vsync ? YES : NO;
    layer.opaque = YES;
    layer.contentsScale = window.backingScaleFactor;
    layer.drawableSize = CGSizeMake(width > 0 ? width : 1, height > 0 ? height : 1);
    view.layer = layer;
    return (jlong)(uintptr_t)layer;
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nSurfaceResize)(JNIEnv *, jclass, jlong layerHandle, jint width,
                                                         jint height) {
  CAMetalLayer *layer = (CAMetalLayer *)(uintptr_t)layerHandle;
  if (!layer || width <= 0 || height <= 0)
    return;
  layer.drawableSize = CGSizeMake(width, height);
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nSurfaceSetVsync)(JNIEnv *, jclass, jlong layerHandle, jboolean vsync) {
  CAMetalLayer *layer = (CAMetalLayer *)(uintptr_t)layerHandle;
  if (layer)
    layer.displaySyncEnabled = vsync ? YES : NO;
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nBufferCreate)(JNIEnv *, jclass, jlong device, jlong size,
                                                         jboolean writeCombined) {
  id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
  MTLResourceOptions options = MTLResourceStorageModeShared;
  if (writeCombined)
    options |= MTLResourceCPUCacheModeWriteCombined;
  id<MTLBuffer> buffer = [d newBufferWithLength:(NSUInteger)(size > 0 ? size : 4) options:options];
  if (!buffer)
    g_backendLastError = "newBufferWithLength failed";
  return (jlong)(uintptr_t)buffer;
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nBufferContents)(JNIEnv *, jclass, jlong buffer) {
  id<MTLBuffer> b = (id<MTLBuffer>)(uintptr_t)buffer;
  return b ? (jlong)(uintptr_t)[b contents] : 0;
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nSetLabel)(JNIEnv *env, jclass, jlong object, jstring label) {
  if (!object || !label)
    return;
  @autoreleasepool {
    std::string s = mr_jstring(env, label);
    id<MTLResource> res = (id<MTLResource>)(uintptr_t)object;
    res.label = [NSString stringWithUTF8String:s.c_str()];
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nTextureCreate)(JNIEnv *, jclass, jlong device, jint type, jint format,
                                                          jint width, jint height, jint depthOrLayers,
                                                          jint mipLevels, jint usage, jint storage) {
  @autoreleasepool {
    id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = (MTLTextureType)type;
    desc.pixelFormat = (MTLPixelFormat)format;
    desc.width = (NSUInteger)width;
    desc.height = (NSUInteger)height;
    desc.depth = 1;
    desc.arrayLength = desc.textureType == MTLTextureType2DArray ? (NSUInteger)depthOrLayers : 1;
    desc.mipmapLevelCount = (NSUInteger)(mipLevels > 0 ? mipLevels : 1);
    desc.usage = (MTLTextureUsage)usage;
    desc.storageMode = (MTLStorageMode)storage;
    id<MTLTexture> tex = [d newTextureWithDescriptor:desc];
    [desc release];
    if (!tex)
      g_backendLastError = "newTextureWithDescriptor failed";
    return (jlong)(uintptr_t)tex;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nTextureView)(JNIEnv *, jclass, jlong texture, jint format, jint type,
                                                        jint baseMip, jint mipCount, jint baseSlice,
                                                        jint sliceCount) {
  id<MTLTexture> tex = (id<MTLTexture>)(uintptr_t)texture;
  if (!tex)
    return 0;
  id<MTLTexture> view = [tex newTextureViewWithPixelFormat:(MTLPixelFormat)format
                                               textureType:(MTLTextureType)type
                                                    levels:NSMakeRange((NSUInteger)baseMip, (NSUInteger)mipCount)
                                                    slices:NSMakeRange((NSUInteger)baseSlice, (NSUInteger)sliceCount)];
  if (!view)
    g_backendLastError = "newTextureViewWithPixelFormat failed";
  return (jlong)(uintptr_t)view;
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nSamplerCreate)(JNIEnv *, jclass, jlong device, jint addressU,
                                                          jint addressV, jint minFilter, jint magFilter,
                                                          jint mipFilter, jint maxAnisotropy, jfloat lodMax) {
  @autoreleasepool {
    id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
    MTLSamplerDescriptor *desc = [[MTLSamplerDescriptor alloc] init];
    desc.sAddressMode = (MTLSamplerAddressMode)addressU;
    desc.tAddressMode = (MTLSamplerAddressMode)addressV;
    desc.rAddressMode = (MTLSamplerAddressMode)addressU;
    desc.minFilter = (MTLSamplerMinMagFilter)minFilter;
    desc.magFilter = (MTLSamplerMinMagFilter)magFilter;
    desc.mipFilter = (MTLSamplerMipFilter)mipFilter;
    desc.maxAnisotropy = (NSUInteger)(maxAnisotropy < 1 ? 1 : maxAnisotropy);
    desc.lodMinClamp = 0.0f;
    desc.lodMaxClamp = lodMax;
    id<MTLSamplerState> s = [d newSamplerStateWithDescriptor:desc];
    [desc release];
    return (jlong)(uintptr_t)s;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nDepthStencilCreate)(JNIEnv *, jclass, jlong device, jint compare,
                                                               jboolean write) {
  @autoreleasepool {
    id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
    MTLDepthStencilDescriptor *desc = [[MTLDepthStencilDescriptor alloc] init];
    desc.depthCompareFunction = (MTLCompareFunction)compare;
    desc.depthWriteEnabled = write ? YES : NO;
    id<MTLDepthStencilState> s = [d newDepthStencilStateWithDescriptor:desc];
    [desc release];
    return (jlong)(uintptr_t)s;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nRenderPipelineCreate)(JNIEnv *env, jclass, jlong device,
                                                                 jlong library, jstring vertexName,
                                                                 jstring fragmentName, jintArray constants,
                                                                 jintArray vertexLayout, jint colorFormat,
                                                                 jint depthFormat, jintArray blend,
                                                                 jint writeMask, jint topologyClass) {
  @autoreleasepool {
    id<MTLDevice> d = (id<MTLDevice>)(uintptr_t)device;
    id<MTLLibrary> lib = (id<MTLLibrary>)(uintptr_t)library;
    MTLFunctionConstantValues *values = [[[MTLFunctionConstantValues alloc] init] autorelease];
    if (constants) {
      jsize n = env->GetArrayLength(constants);
      jint *c = env->GetIntArrayElements(constants, nullptr);
      for (jsize i = 0; i + 2 < n; i += 3) {
        NSUInteger index = (NSUInteger)c[i];
        int kind = c[i + 1];
        int raw = c[i + 2];
        if (kind == 0) {
          bool b = raw != 0;
          [values setConstantValue:&b type:MTLDataTypeBool atIndex:index];
        } else if (kind == 1) {
          int v = raw;
          [values setConstantValue:&v type:MTLDataTypeInt atIndex:index];
        } else {
          float f;
          memcpy(&f, &raw, sizeof(float));
          [values setConstantValue:&f type:MTLDataTypeFloat atIndex:index];
        }
      }
      env->ReleaseIntArrayElements(constants, c, JNI_ABORT);
    }
    NSError *error = nil;
    std::string vn = mr_jstring(env, vertexName);
    std::string fn = mr_jstring(env, fragmentName);
    id<MTLFunction> vf = [[lib newFunctionWithName:[NSString stringWithUTF8String:vn.c_str()]
                                    constantValues:values
                                             error:&error] autorelease];
    if (!vf) {
      mr_set_error(error, ("vertex function " + vn).c_str());
      return 0;
    }
    id<MTLFunction> ff = [[lib newFunctionWithName:[NSString stringWithUTF8String:fn.c_str()]
                                    constantValues:values
                                             error:&error] autorelease];
    if (!ff) {
      mr_set_error(error, ("fragment function " + fn).c_str());
      return 0;
    }
    MTLRenderPipelineDescriptor *desc = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
    desc.vertexFunction = vf;
    desc.fragmentFunction = ff;
    if (vertexLayout) {
      jsize n = env->GetArrayLength(vertexLayout);
      jint *v = env->GetIntArrayElements(vertexLayout, nullptr);
      if (n >= 1 && v[0] > 0) {
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.layouts[MR_SLOT_VERTEX].stride = (NSUInteger)v[0];
        vd.layouts[MR_SLOT_VERTEX].stepFunction = MTLVertexStepFunctionPerVertex;
        vd.layouts[MR_SLOT_VERTEX].stepRate = 1;
        for (jsize i = 1; i + 2 < n; i += 3) {
          NSUInteger attr = (NSUInteger)v[i];
          vd.attributes[attr].format = (MTLVertexFormat)v[i + 1];
          vd.attributes[attr].offset = (NSUInteger)v[i + 2];
          vd.attributes[attr].bufferIndex = MR_SLOT_VERTEX;
        }
        desc.vertexDescriptor = vd;
      }
      env->ReleaseIntArrayElements(vertexLayout, v, JNI_ABORT);
    }
    desc.colorAttachments[0].pixelFormat = (MTLPixelFormat)colorFormat;
    desc.depthAttachmentPixelFormat = (MTLPixelFormat)depthFormat;
    desc.inputPrimitiveTopology = (MTLPrimitiveTopologyClass)topologyClass;
    if (colorFormat != (jint)MTLPixelFormatInvalid) {
      desc.colorAttachments[0].writeMask = (MTLColorWriteMask)writeMask;
      if (blend) {
        jint *b = env->GetIntArrayElements(blend, nullptr);
        if (b[0]) {
          desc.colorAttachments[0].blendingEnabled = YES;
          desc.colorAttachments[0].sourceRGBBlendFactor = (MTLBlendFactor)b[1];
          desc.colorAttachments[0].destinationRGBBlendFactor = (MTLBlendFactor)b[2];
          desc.colorAttachments[0].sourceAlphaBlendFactor = (MTLBlendFactor)b[3];
          desc.colorAttachments[0].destinationAlphaBlendFactor = (MTLBlendFactor)b[4];
          desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
          desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        }
        env->ReleaseIntArrayElements(blend, b, JNI_ABORT);
      }
    }
    id<MTLRenderPipelineState> pso = [d newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!pso) {
      mr_set_error(error, ("pipeline " + vn + "/" + fn).c_str());
      return 0;
    }
    return (jlong)(uintptr_t)pso;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nCtxCreate)(JNIEnv *, jclass, jlong device, jlong queue,
                                                      jlong library) {
  @autoreleasepool {
    MRContext *ctx = new MRContext();
    ctx->device = [(id<MTLDevice>)(uintptr_t)device retain];
    ctx->queue = [(id<MTLCommandQueue>)(uintptr_t)queue retain];
    ctx->library = [(id<MTLLibrary>)(uintptr_t)library retain];
    ctx->event = [ctx->device newSharedEvent];
    ctx->event.signaledValue = 0;
    ctx->frameSemaphore = dispatch_semaphore_create(2);
    NSError *error = nil;
    MTLRenderPipelineDescriptor *desc = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
    desc.vertexFunction = [[ctx->library newFunctionWithName:@"mr_present_vertex"] autorelease];
    desc.fragmentFunction = [[ctx->library newFunctionWithName:@"mr_present_fragment"] autorelease];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    ctx->presentPipeline = [ctx->device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!ctx->presentPipeline) {
      mr_set_error(error, "present pipeline");
      [ctx->event release];
      [ctx->library release];
      [ctx->queue release];
      [ctx->device release];
      delete ctx;
      return 0;
    }
    MTLDepthStencilDescriptor *dsd = [[[MTLDepthStencilDescriptor alloc] init] autorelease];
    dsd.depthCompareFunction = MTLCompareFunctionAlways;
    dsd.depthWriteEnabled = YES;
    ctx->clearDepthWrite = [ctx->device newDepthStencilStateWithDescriptor:dsd];
    dsd.depthWriteEnabled = NO;
    ctx->clearDepthKeep = [ctx->device newDepthStencilStateWithDescriptor:dsd];
    return (jlong)(uintptr_t)ctx;
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxDestroy)(JNIEnv *, jclass, jlong handle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx)
    return;
  mr_end_encoders(ctx);
  if (ctx->cmd) {
    [ctx->cmd commit];
    [ctx->cmd waitUntilCompleted];
    [ctx->cmd release];
    ctx->cmd = nil;
  }
  for (auto &entry : ctx->clearPipelines)
    [entry.second release];
  [ctx->clearDepthWrite release];
  [ctx->clearDepthKeep release];
  [ctx->presentPipeline release];
  [ctx->event release];
  [ctx->library release];
  [ctx->queue release];
  [ctx->device release];
  if (ctx->frameSemaphore)
    dispatch_release(ctx->frameSemaphore);
  delete ctx;
}

extern "C" JNIEXPORT jboolean JNICALL MR_JNI(nCtxBeginRender)(JNIEnv *env, jclass, jlong handle, jstring label,
                                                              jlong colorTex, jint colorLevel, jint colorSlice,
                                                              jboolean clearColor, jfloat r, jfloat g, jfloat b,
                                                              jfloat a, jlong depthTex, jint depthLevel,
                                                              jint depthSlice, jboolean clearDepth,
                                                              jdouble depth) {
  @autoreleasepool {
    MRContext *ctx = (MRContext *)(uintptr_t)handle;
    mr_end_encoders(ctx);
    id<MTLTexture> color = (id<MTLTexture>)(uintptr_t)colorTex;
    id<MTLTexture> depthTexture = (id<MTLTexture>)(uintptr_t)depthTex;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    int width = 0, height = 0;
    if (color) {
      rp.colorAttachments[0].texture = color;
      rp.colorAttachments[0].level = (NSUInteger)colorLevel;
      rp.colorAttachments[0].slice = (NSUInteger)colorSlice;
      rp.colorAttachments[0].loadAction = clearColor ? MTLLoadActionClear : MTLLoadActionLoad;
      rp.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
      rp.colorAttachments[0].storeAction = MTLStoreActionStore;
      width = (int)MAX((NSUInteger)1, color.width >> colorLevel);
      height = (int)MAX((NSUInteger)1, color.height >> colorLevel);
    }
    if (depthTexture) {
      rp.depthAttachment.texture = depthTexture;
      rp.depthAttachment.level = (NSUInteger)depthLevel;
      rp.depthAttachment.slice = (NSUInteger)depthSlice;
      rp.depthAttachment.loadAction = clearDepth ? MTLLoadActionClear : MTLLoadActionLoad;
      rp.depthAttachment.clearDepth = depth;
      rp.depthAttachment.storeAction = MTLStoreActionStore;
      if (!color) {
        width = (int)MAX((NSUInteger)1, depthTexture.width >> depthLevel);
        height = (int)MAX((NSUInteger)1, depthTexture.height >> depthLevel);
      }
    }
    if (!color && !depthTexture) {
      g_backendLastError = "render pass without attachments";
      return JNI_FALSE;
    }
    ctx->render = [[mr_cmd(ctx) renderCommandEncoderWithDescriptor:rp] retain];
    if (!ctx->render) {
      g_backendLastError = "renderCommandEncoderWithDescriptor failed";
      return JNI_FALSE;
    }
    if (label) {
      std::string s = mr_jstring(env, label);
      ctx->render.label = [NSString stringWithUTF8String:s.c_str()];
    }
    ctx->targetWidth = width;
    ctx->targetHeight = height;
    ctx->colorFormat = color ? color.pixelFormat : MTLPixelFormatInvalid;
    ctx->depthFormat = depthTexture ? depthTexture.pixelFormat : MTLPixelFormatInvalid;
    MTLViewport vp = {0.0, 0.0, (double)width, (double)height, 0.0, 1.0};
    [ctx->render setViewport:vp];
    return JNI_TRUE;
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxEndEncoder)(JNIEnv *, jclass, jlong handle) {
  mr_end_encoders((MRContext *)(uintptr_t)handle);
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxPushDebugGroup)(JNIEnv *env, jclass, jlong handle, jstring label) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render || !label)
    return;
  @autoreleasepool {
    std::string s = mr_jstring(env, label);
    [ctx->render pushDebugGroup:[NSString stringWithUTF8String:s.c_str()]];
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxPopDebugGroup)(JNIEnv *, jclass, jlong handle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (ctx->render)
    [ctx->render popDebugGroup];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxSetPipeline)(JNIEnv *, jclass, jlong handle, jlong pso, jlong dss,
                                                          jint cullMode, jint winding, jint fillMode,
                                                          jfloat depthBias, jfloat slopeScale) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  [ctx->render setRenderPipelineState:(id<MTLRenderPipelineState>)(uintptr_t)pso];
  if (dss)
    [ctx->render setDepthStencilState:(id<MTLDepthStencilState>)(uintptr_t)dss];
  [ctx->render setCullMode:(MTLCullMode)cullMode];
  [ctx->render setFrontFacingWinding:(MTLWinding)winding];
  [ctx->render setTriangleFillMode:(MTLTriangleFillMode)fillMode];
  [ctx->render setDepthBias:depthBias slopeScale:slopeScale clamp:0.0f];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxSetVertexBuffer)(JNIEnv *, jclass, jlong handle, jlong buffer,
                                                              jlong offset, jint index) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  [ctx->render setVertexBuffer:(id<MTLBuffer>)(uintptr_t)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxSetBuffer)(JNIEnv *, jclass, jlong handle, jlong buffer, jlong offset,
                                                        jint index) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  id<MTLBuffer> b = (id<MTLBuffer>)(uintptr_t)buffer;
  [ctx->render setVertexBuffer:b offset:(NSUInteger)offset atIndex:(NSUInteger)index];
  [ctx->render setFragmentBuffer:b offset:(NSUInteger)offset atIndex:(NSUInteger)index];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxSetTexture)(JNIEnv *, jclass, jlong handle, jlong texture,
                                                         jlong samplerState, jint index) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  id<MTLTexture> t = (id<MTLTexture>)(uintptr_t)texture;
  id<MTLSamplerState> s = (id<MTLSamplerState>)(uintptr_t)samplerState;
  [ctx->render setVertexTexture:t atIndex:(NSUInteger)index];
  [ctx->render setFragmentTexture:t atIndex:(NSUInteger)index];
  if (s) {
    NSUInteger samplerIndex = (NSUInteger)(index == MR_TEX_CUBE ? 0 : index);
    [ctx->render setVertexSamplerState:s atIndex:samplerIndex];
    [ctx->render setFragmentSamplerState:s atIndex:samplerIndex];
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxSetScissor)(JNIEnv *, jclass, jlong handle, jint x, jint y, jint w,
                                                         jint h) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  int x0 = MAX(0, MIN(x, ctx->targetWidth));
  int y0 = MAX(0, MIN(y, ctx->targetHeight));
  int x1 = MAX(x0, MIN(x + w, ctx->targetWidth));
  int y1 = MAX(y0, MIN(y + h, ctx->targetHeight));
  MTLScissorRect rect = {(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
  [ctx->render setScissorRect:rect];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxDraw)(JNIEnv *, jclass, jlong handle, jint primitive, jint start,
                                                   jint count, jint instances) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render || count <= 0)
    return;
  [ctx->render drawPrimitives:(MTLPrimitiveType)primitive
                  vertexStart:(NSUInteger)start
                  vertexCount:(NSUInteger)count
                instanceCount:(NSUInteger)(instances > 0 ? instances : 1)];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxDrawIndexed)(JNIEnv *, jclass, jlong handle, jint primitive,
                                                          jint indexCount, jboolean index32, jlong indexBuffer,
                                                          jlong indexOffset, jint instances, jint baseVertex) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render || indexCount <= 0 || !indexBuffer)
    return;
  [ctx->render drawIndexedPrimitives:(MTLPrimitiveType)primitive
                          indexCount:(NSUInteger)indexCount
                           indexType:index32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                         indexBuffer:(id<MTLBuffer>)(uintptr_t)indexBuffer
                   indexBufferOffset:(NSUInteger)indexOffset
                       instanceCount:(NSUInteger)(instances > 0 ? instances : 1)
                          baseVertex:(NSInteger)baseVertex
                        baseInstance:0];
}

static id<MTLRenderPipelineState> mr_clear_pipeline(MRContext *ctx) {
  uint64_t key = ((uint64_t)ctx->colorFormat << 32) | (uint64_t)ctx->depthFormat;
  auto it = ctx->clearPipelines.find(key);
  if (it != ctx->clearPipelines.end())
    return it->second;
  NSError *error = nil;
  MTLRenderPipelineDescriptor *desc = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
  desc.vertexFunction = [[ctx->library newFunctionWithName:@"mr_clear_vertex"] autorelease];
  desc.fragmentFunction = [[ctx->library newFunctionWithName:@"mr_clear_fragment"] autorelease];
  desc.colorAttachments[0].pixelFormat = ctx->colorFormat;
  desc.depthAttachmentPixelFormat = ctx->depthFormat;
  id<MTLRenderPipelineState> pso = [ctx->device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (!pso) {
    mr_set_error(error, "clear pipeline");
    return nil;
  }
  ctx->clearPipelines[key] = pso;
  return pso;
}

extern "C" JNIEXPORT jboolean JNICALL MR_JNI(nCtxClearRect)(JNIEnv *, jclass, jlong handle, jint x, jint y, jint w,
                                                            jint h, jfloat r, jfloat g, jfloat b, jfloat a,
                                                            jfloat depth, jboolean writeDepth) {
  @autoreleasepool {
    MRContext *ctx = (MRContext *)(uintptr_t)handle;
    if (!ctx->render)
      return JNI_FALSE;
    id<MTLRenderPipelineState> pso = mr_clear_pipeline(ctx);
    if (!pso)
      return JNI_FALSE;
    struct {
      float color[4];
      float depth;
    } params = {{r, g, b, a}, depth};
    [ctx->render setRenderPipelineState:pso];
    [ctx->render setDepthStencilState:writeDepth ? ctx->clearDepthWrite : ctx->clearDepthKeep];
    [ctx->render setCullMode:MTLCullModeNone];
    [ctx->render setTriangleFillMode:MTLTriangleFillModeFill];
    [ctx->render setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
    [ctx->render setVertexBytes:&params length:sizeof(params) atIndex:0];
    [ctx->render setFragmentBytes:&params length:sizeof(params) atIndex:0];
    int x0 = MAX(0, MIN(x, ctx->targetWidth));
    int y0 = MAX(0, MIN(y, ctx->targetHeight));
    int x1 = MAX(x0, MIN(x + w, ctx->targetWidth));
    int y1 = MAX(y0, MIN(y + h, ctx->targetHeight));
    MTLScissorRect rect = {(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
    [ctx->render setScissorRect:rect];
    if (x1 > x0 && y1 > y0)
      [ctx->render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    MTLScissorRect full = {0, 0, (NSUInteger)ctx->targetWidth, (NSUInteger)ctx->targetHeight};
    [ctx->render setScissorRect:full];
    return JNI_TRUE;
  }
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxCopyBuffer)(JNIEnv *, jclass, jlong handle, jlong src, jlong srcOffset,
                                                         jlong dst, jlong dstOffset, jlong length) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (length <= 0)
    return;
  [mr_blit(ctx) copyFromBuffer:(id<MTLBuffer>)(uintptr_t)src
                  sourceOffset:(NSUInteger)srcOffset
                      toBuffer:(id<MTLBuffer>)(uintptr_t)dst
             destinationOffset:(NSUInteger)dstOffset
                          size:(NSUInteger)length];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxCopyBufferToTexture)(JNIEnv *, jclass, jlong handle, jlong src,
                                                                  jlong srcOffset, jint bytesPerRow,
                                                                  jint bytesPerImage, jlong texture, jint slice,
                                                                  jint mip, jint x, jint y, jint w, jint h) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (w <= 0 || h <= 0)
    return;
  [mr_blit(ctx) copyFromBuffer:(id<MTLBuffer>)(uintptr_t)src
                  sourceOffset:(NSUInteger)srcOffset
             sourceBytesPerRow:(NSUInteger)bytesPerRow
           sourceBytesPerImage:(NSUInteger)bytesPerImage
                    sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                     toTexture:(id<MTLTexture>)(uintptr_t)texture
              destinationSlice:(NSUInteger)slice
              destinationLevel:(NSUInteger)mip
             destinationOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxCopyTextureToBuffer)(JNIEnv *, jclass, jlong handle, jlong texture,
                                                                  jint slice, jint mip, jint x, jint y, jint w,
                                                                  jint h, jlong dst, jlong dstOffset,
                                                                  jint bytesPerRow, jint bytesPerImage) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (w <= 0 || h <= 0)
    return;
  [mr_blit(ctx) copyFromTexture:(id<MTLTexture>)(uintptr_t)texture
                    sourceSlice:(NSUInteger)slice
                    sourceLevel:(NSUInteger)mip
                   sourceOrigin:MTLOriginMake((NSUInteger)x, (NSUInteger)y, 0)
                     sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                       toBuffer:(id<MTLBuffer>)(uintptr_t)dst
              destinationOffset:(NSUInteger)dstOffset
         destinationBytesPerRow:(NSUInteger)bytesPerRow
       destinationBytesPerImage:(NSUInteger)bytesPerImage];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxCopyTextureToTexture)(JNIEnv *, jclass, jlong handle, jlong src,
                                                                   jint srcSlice, jint srcMip, jint sx, jint sy,
                                                                   jlong dst, jint dstSlice, jint dstMip, jint dx,
                                                                   jint dy, jint w, jint h) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (w <= 0 || h <= 0)
    return;
  [mr_blit(ctx) copyFromTexture:(id<MTLTexture>)(uintptr_t)src
                    sourceSlice:(NSUInteger)srcSlice
                    sourceLevel:(NSUInteger)srcMip
                   sourceOrigin:MTLOriginMake((NSUInteger)sx, (NSUInteger)sy, 0)
                     sourceSize:MTLSizeMake((NSUInteger)w, (NSUInteger)h, 1)
                      toTexture:(id<MTLTexture>)(uintptr_t)dst
               destinationSlice:(NSUInteger)dstSlice
               destinationLevel:(NSUInteger)dstMip
              destinationOrigin:MTLOriginMake((NSUInteger)dx, (NSUInteger)dy, 0)];
}

extern "C" JNIEXPORT jboolean JNICALL MR_JNI(nCtxPresent)(JNIEnv *, jclass, jlong handle, jlong layerHandle,
                                                          jlong sourceTexture) {
  @autoreleasepool {
    MRContext *ctx = (MRContext *)(uintptr_t)handle;
    CAMetalLayer *layer = (CAMetalLayer *)(uintptr_t)layerHandle;
    id<MTLTexture> source = (id<MTLTexture>)(uintptr_t)sourceTexture;
    mr_end_encoders(ctx);
    if (!layer || !source)
      return JNI_FALSE;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable)
      return JNI_FALSE;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable.texture;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cmd = mr_cmd(ctx);
    id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rp];
    enc.label = @"metalrender present";
    MTLViewport vp = {0.0, 0.0, (double)drawable.texture.width, (double)drawable.texture.height, 0.0, 1.0};
    [enc setViewport:vp];
    [enc setRenderPipelineState:ctx->presentPipeline];
    [enc setFragmentTexture:source atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    [cmd presentDrawable:drawable];
    return JNI_TRUE;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nCtxSubmit)(JNIEnv *, jclass, jlong handle, jboolean frameEnd) {
  @autoreleasepool {
    MRContext *ctx = (MRContext *)(uintptr_t)handle;
    mr_end_encoders(ctx);
    id<MTLCommandBuffer> cmd = mr_cmd(ctx);
    uint64_t serial = ctx->openSerial++;
    [cmd encodeSignalEvent:ctx->event value:serial];
    if (frameEnd) {
      dispatch_semaphore_t sem = ctx->frameSemaphore;
      [cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
        dispatch_semaphore_signal(sem);
      }];
    }
    [cmd commit];
    [cmd release];
    ctx->cmd = nil;
    if (frameEnd)
      dispatch_semaphore_wait(ctx->frameSemaphore, DISPATCH_TIME_FOREVER);
    return (jlong)serial;
  }
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nCtxCompleted)(JNIEnv *, jclass, jlong handle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  return (jlong)ctx->event.signaledValue;
}

extern "C" JNIEXPORT jboolean JNICALL MR_JNI(nCtxWait)(JNIEnv *, jclass, jlong handle, jlong serial,
                                                       jlong timeoutMs) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (ctx->event.signaledValue >= (uint64_t)serial)
    return JNI_TRUE;
  if (timeoutMs <= 0)
    return JNI_FALSE;
  return [ctx->event waitUntilSignaledValue:(uint64_t)serial timeoutMS:(uint64_t)timeoutMs] ? JNI_TRUE : JNI_FALSE;
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nQueryCreate)(JNIEnv *, jclass) {
  return (jlong)(uintptr_t) new MRQuery();
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nQueryRelease)(JNIEnv *, jclass, jlong handle) {
  if (handle)
    mr_query_release((MRQuery *)(uintptr_t)handle);
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxQueryBegin)(JNIEnv *, jclass, jlong handle, jlong queryHandle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  MRQuery *q = (MRQuery *)(uintptr_t)queryHandle;
  q->refs.fetch_add(1);
  [mr_cmd(ctx) addScheduledHandler:^(id<MTLCommandBuffer>) {
    q->startNs.store(mr_now_ns());
    q->started.store(true);
    mr_query_release(q);
  }];
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxQueryEnd)(JNIEnv *, jclass, jlong handle, jlong queryHandle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  MRQuery *q = (MRQuery *)(uintptr_t)queryHandle;
  q->refs.fetch_add(1);
  [mr_cmd(ctx) addCompletedHandler:^(id<MTLCommandBuffer>) {
    q->endNs.store(mr_now_ns());
    q->ended.store(true);
    mr_query_release(q);
  }];
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nQueryValue)(JNIEnv *, jclass, jlong queryHandle) {
  MRQuery *q = (MRQuery *)(uintptr_t)queryHandle;
  if (!q->started.load() || !q->ended.load())
    return -1;
  uint64_t s = q->startNs.load();
  uint64_t e = q->endNs.load();
  return (jlong)(e > s ? e - s : 0);
}

extern "C" JNIEXPORT jlong JNICALL MR_JNI(nCtxRenderEncoder)(JNIEnv *, jclass, jlong handle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  return (jlong)(uintptr_t)ctx->render;
}

extern "C" JNIEXPORT void JNICALL MR_JNI(nCtxRestoreViewport)(JNIEnv *, jclass, jlong handle) {
  MRContext *ctx = (MRContext *)(uintptr_t)handle;
  if (!ctx->render)
    return;
  MTLViewport vp = {0.0, 0.0, (double)ctx->targetWidth, (double)ctx->targetHeight, 0.0, 1.0};
  [ctx->render setViewport:vp];
  MTLScissorRect full = {0, 0, (NSUInteger)ctx->targetWidth, (NSUInteger)ctx->targetHeight};
  [ctx->render setScissorRect:full];
}
