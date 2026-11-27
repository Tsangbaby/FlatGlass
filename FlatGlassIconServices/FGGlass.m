//
//  FGGlass.m
//  “玻璃 / 描边”三个生成器。
//
//  地址对照：0x68cc NGCreateGlassIconContent / 0x68f8 NGCreateGlassIcon
//            0x9324 NGCreateRimmedImage        / 0x996c NGCreateGlassedImage
//
//  ⚠️ 保真度说明
//  -------------
//  NGCreateGlassIcon 是原二进制里最大的函数（0x1570 字节 / 约 1372 条指令）：
//  它把每个元素渲染成 BGRA → 转 float 平面 → 逐元素做 IGDrawGroup 玻璃合成
//  （法线/SDF 光照、半透明、镜面、投影）→ 最后统一叠 chiclet 高光与描边。
//  逐指令还原稿见 reverse-reference/B_glass.c（含全部常量与分支）。
//
//  This test build restores per-contour outer highlights. The original full
//  multi-pass artwork glass composition is not implemented here.
//

#import "FGInternal.h"
#include <math.h>
#include <stdlib.h>

#pragma mark - 通用：CGImage -> float RGB 平面 -> CGImage

typedef struct {
    float *rgb;      // 3 float / 像素
    float *alpha;    // 1 float / 像素
    int    n;
} FGPlanes;

static BOOL FGLoadPlanes(CGImageRef src, FGPlanes *out) {
    if (!src) return NO;
    size_t w = CGImageGetWidth(src), h = CGImageGetHeight(src);
    if (!w || w != h || w > FG_MAX_PIXELS) return NO;
    int n = (int)w;

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) return NO;
    CGContextRef c = CGBitmapContextCreate(NULL, n, n, 8, 0, cs,
                                           kCGBitmapByteOrder32Little |
                                           kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!c) return NO;

    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextDrawImage(c, CGRectMake(0, 0, n, n), src);

    const uint8_t *data = CGBitmapContextGetData(c);
    size_t stride = CGBitmapContextGetBytesPerRow(c);
    float *rgb = calloc((size_t)n * n * 3, sizeof(float));
    float *alpha = malloc((size_t)n * n * sizeof(float));
    if (!data || !rgb || !alpha) {
        free(rgb); free(alpha);
        CGContextRelease(c);
        return NO;
    }

    for (int y = 0; y < n; y++) {
        const uint8_t *row = data + (size_t)y * stride;
        for (int x = 0; x < n; x++) {
            const uint8_t *p = row + x * 4;             // BGRA，预乘
            size_t i = (size_t)y * n + x;
            float a = (float)p[3] / 255.0f;
            if (a > 0.0f) {
                rgb[i * 3 + 0] = (float)p[2] / 255.0f / a;
                rgb[i * 3 + 1] = (float)p[1] / 255.0f / a;
                rgb[i * 3 + 2] = (float)p[0] / 255.0f / a;
            }
            alpha[i] = a;
        }
    }

    CGContextRelease(c);
    out->rgb = rgb; out->alpha = alpha; out->n = n;
    return YES;
}

static CGImageRef FGStorePlanes(FGPlanes *p, const float *shape) {
    const int n = p->n;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    if (!cs) return NULL;
    CGContextRef c = CGBitmapContextCreate(NULL, n, n, 8, 0, cs,
                                           kCGBitmapByteOrder32Little |
                                           kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!c) return NULL;

    uint8_t *data = CGBitmapContextGetData(c);
    if (!data) { CGContextRelease(c); return NULL; }
    size_t stride = CGBitmapContextGetBytesPerRow(c);

    for (int y = 0; y < n; y++) {
        uint8_t *row = data + (size_t)y * stride;
        for (int x = 0; x < n; x++) {
            size_t i = (size_t)y * n + x;
            float a = p->alpha[i];
            if (shape) a *= shape[i];
            if (a < 0.0f) a = 0.0f;
            if (a > 1.0f) a = 1.0f;

            float r = p->rgb[i * 3 + 0], g = p->rgb[i * 3 + 1], b = p->rgb[i * 3 + 2];
            if (r < 0) r = 0; else if (r > 1) r = 1;
            if (g < 0) g = 0; else if (g > 1) g = 1;
            if (b < 0) b = 0; else if (b > 1) b = 1;

            uint8_t *px = row + x * 4;                  // BGRA 预乘
            px[3] = (uint8_t)lrintf(a * 255.0f);
            px[0] = (uint8_t)lrintf(b * a * 255.0f);
            px[1] = (uint8_t)lrintf(g * a * 255.0f);
            px[2] = (uint8_t)lrintf(r * a * 255.0f);
        }
    }

    CGImageRef out = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    return out;
}

#pragma mark - 入口

// [v1 近似] 用分层资源先做扁平重建，再叠形状描边 / chiclet 高光。
// gGlassNoEdge 的语义保持为逐次调用参数，避免并发渲染互相改变高光。
static CGImageRef FGCreateGlassIcon(id catalog, NSString *name, uint32_t appearance,
                                        size_t px, BOOL suppressChiclet) {
    CGImageRef flat = NGCreateFlatIcon(catalog, name, appearance, px);
    if (!flat) return NULL;

    FGPlanes planes = {0};
    BOOL loaded = FGLoadPlanes(flat, &planes);
    CGImageRelease(flat);
    if (!loaded) return NULL;   // 由调用方回退到系统图标

    const int n = planes.n;
    float *shape = FGIconShape(n);
    BOOL painted = shape && FGPaintContour(planes.rgb, planes.alpha, shape, n,
                                            !suppressChiclet, true, 0.1f);
    CGImageRef out = painted ? FGStorePlanes(&planes, shape) : NULL;
    free(shape);
    free(planes.rgb);
    free(planes.alpha);
    return out;
}

CGImageRef NGCreateGlassIconContent(id catalog, NSString *name, uint32_t appearance, size_t px) {
    return FGCreateGlassIcon(catalog, name, appearance, px, YES);
}

CGImageRef NGCreateGlassIcon(id catalog, NSString *name, uint32_t appearance, size_t px) {
    return FGCreateGlassIcon(catalog, name, appearance, px, NO);
}

// Original rimmed applies the directional chiclet to the contour; it is not
// the narrow white outline alone. Both composed paths preserve source alpha.
static CGImageRef FGCompositeContour(CGImageRef src, bool artworkStyle) {
    if (!src || CGImageGetWidth(src) < (artworkStyle ? 16u : 8u)) return NULL;
    FGPlanes planes = {0};
    if (!FGLoadPlanes(src, &planes)) return NULL;
    float *shape = FGIconShape(planes.n);
    bool painted = shape && FGPaintContour(planes.rgb, planes.alpha, shape, planes.n,
                                           true, artworkStyle, 0.1f);
    CGImageRef out = painted ? FGStorePlanes(&planes, NULL) : NULL;
    free(shape);
    free(planes.rgb);
    free(planes.alpha);
    return out;
}

CGImageRef NGCreateRimmedImage(CGImageRef src) {
    return FGCompositeContour(src, false);
}

// Per-artwork glass shading (IGDrawGroup) is still approximate; do not mask
// the source alpha a second time or claim equivalence to the original.
CGImageRef NGCreateGlassedImage(CGImageRef src) {
    return FGCompositeContour(src, true);
}
