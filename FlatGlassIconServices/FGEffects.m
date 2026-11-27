//
//  FGEffects.m
//  FlatGlass
//

#import "FGEffects.h"
#import "FGShape.h"
#import <math.h>
#import <stdlib.h>
#import <string.h>

// 0xd0d0
void IGDrawChicletHighlights(uint8_t *rgba, const float *shape, int w, int h, int flags) {
    if (!rgba || !shape || w <= 0 || h <= 0) return;

    const char *env = getenv("IG_STEPS");
    int steps = env ? (int)atol(env) : 32;
    if (steps < 4) steps = 4;
    if (steps > 256) steps = 256;
    steps *= 4;

    size_t count = (size_t)w * h;

    float *dist = malloc(sizeof(float) * count);
    if (!dist) return;

    // Seed the distance field: inside = far, outside = 0.
    for (size_t i = 0; i < count; i++) {
        dist[i] = shape[i] > 0.5f ? 1e6f : 0.0f;
    }
    FGEDT(dist, w, h);

    for (size_t i = 0; i < count; i++) {
        dist[i] = sqrtf(dist[i]);
    }

    // Light sweep: a diagonal band travelling across the icon, attenuated by
    // distance from the silhouette edge.
    float invW = 1.0f / (float)w;
    float invH = 1.0f / (float)h;
    float bandWidth = 0.5f / (float)steps * 22.0f;

    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            size_t i = (size_t)y * w + x;
            if (shape[i] <= 0.01f) continue;

            float d = dist[i];
            if (d > 22.0f) continue;

            // Edge falloff: strongest right at the rim, gone by 22 px inward.
            float falloff = 1.0f - (d / 22.0f);
            falloff = falloff * falloff;

            // Normalised position drives the sweep; the band is diagonal so the
            // highlight reads as a specular streak rather than a flat gradient.
            float u = ((float)x * invW + (float)y * invH) * 0.5f;
            float sweep = sinf(u * 3.14159265f * (float)steps * 0.5f);
            if (sweep < 0) sweep = 0;

            float amount = falloff * sweep * bandWidth;
            if (amount <= 0) continue;

            // Specular white, clamped per channel.
            for (int c = 0; c < 3; c++) {
                float v = rgba[i * 4 + c] + 255.0f * amount * 0.9f;
                rgba[i * 4 + c] = (uint8_t)(v > 255.0f ? 255.0f : v);
            }
        }
    }

    free(dist);

    // Optional artwork pass: add a soft inner glow along the top third.
    if (flags & 1) {
        for (int y = 0; y < h / 3; y++) {
            float t = 1.0f - (float)y / (float)(h / 3);
            float amount = t * t * 0.12f;
            for (int x = 0; x < w; x++) {
                size_t i = (size_t)y * w + x;
                if (shape[i] <= 0.01f) continue;
                for (int c = 0; c < 3; c++) {
                    float v = rgba[i * 4 + c] + 255.0f * amount;
                    rgba[i * 4 + c] = (uint8_t)(v > 255.0f ? 255.0f : v);
                }
            }
        }
    }
}

// 0xbdec
void IGDrawGroup(uint8_t *dst, uint8_t **layers, const float *opacity,
                 int layerCount, int w, int h) {
    if (!dst || !layers || layerCount <= 0) return;

    size_t count = (size_t)w * h * 4;

    // Start from a transparent canvas.
    memset(dst, 0, count);

    for (int l = 0; l < layerCount; l++) {
        uint8_t *src = layers[l];
        if (!src) continue;

        float alpha = opacity ? opacity[l] : 1.0f;
        if (alpha <= 0) continue;
        if (alpha > 1) alpha = 1;

        for (size_t i = 0; i < (size_t)w * h; i++) {
            float sa = (float)src[i * 4 + 3] / 255.0f * alpha;
            if (sa <= 0) continue;
            float da = (float)dst[i * 4 + 3] / 255.0f;

            // Source-over with straight (non-premultiplied) alpha.
            float outA = sa + da * (1.0f - sa);
            if (outA <= 0) continue;

            for (int c = 0; c < 3; c++) {
                float sc = (float)src[i * 4 + c];
                float dc = (float)dst[i * 4 + c];
                float out = (sc * sa + dc * da * (1.0f - sa)) / outA;
                dst[i * 4 + c] = (uint8_t)(out > 255.0f ? 255.0f : out);
            }
            dst[i * 4 + 3] = (uint8_t)(outA * 255.0f);
        }
    }
}
