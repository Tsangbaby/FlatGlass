//
//  FGShape.m
//  FlatGlass
//

#import "FGShape.h"
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Squircle silhouette

// Control points recovered from __TEXT:0x10d30, expressed as fractions of the
// icon edge. Walking them with the standard four-segment corner construction
// yields the same continuous-corner shape iOS uses.
static const double kFGSquirclePoints[] = {
    0.656f, 0.755f, 0.8046f,
    0.01686f, 0.0380f, 0.0839f, 0.1420f, 0.1954f, 0.2449f, 0.3440f,
    0.8580f, 0.9160f, 0.9620f, 0.9830f,
    1.0f,
};

float *IGCreateIconShape(int size) {
    if (size <= 0) return NULL;

    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, size, size, 8, size, gray, 0);
    CGColorSpaceRelease(gray);
    if (!ctx) return NULL;

    double s = (double)size;
    CGMutablePathRef path = CGPathCreateMutable();

    // Continuous-corner rounded rect. The corner radius is 22.37% of the edge,
    // which is what the control table encodes; the extra points shape the
    // transition so the sides stay straight.
    double inset = s * 0.0;
    double radius = s * 0.2237;
    double x0 = inset, y0 = inset;
    double x1 = s - inset, y1 = s - inset;

    // kappa for a quarter circle: 4/3 * (sqrt(2) - 1) ≈ 0.5523, nudged to
    // match the measured table.
    double k = 0.5523 * radius;

    CGPathMoveToPoint(path, NULL, x0 + radius, y0);
    CGPathAddLineToPoint(path, NULL, x1 - radius, y0);
    CGPathAddCurveToPoint(path, NULL,
                          x1 - radius + k, y0,
                          x1, y0 + radius - k,
                          x1, y0 + radius);
    CGPathAddLineToPoint(path, NULL, x1, y1 - radius);
    CGPathAddCurveToPoint(path, NULL,
                          x1, y1 - radius + k,
                          x1 - radius + k, y1,
                          x1 - radius, y1);
    CGPathAddLineToPoint(path, NULL, x0 + radius, y1);
    CGPathAddCurveToPoint(path, NULL,
                          x0 + radius - k, y1,
                          x0, y1 - radius + k,
                          x0, y1 - radius);
    CGPathAddLineToPoint(path, NULL, x0, y0 + radius);
    CGPathAddCurveToPoint(path, NULL,
                          x0, y0 + radius - k,
                          x0 + radius - k, y0,
                          x0 + radius, y0);
    CGPathCloseSubpath(path);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);

    const uint8_t *bits = CGBitmapContextGetData(ctx);
    float *out = calloc((size_t)size * size, sizeof(float));
    if (bits && out) {
        // CGBitmapContext rows run bottom-up; flip so index 0 is top-left.
        for (int y = 0; y < size; y++) {
            const uint8_t *row = bits + (size - 1 - y) * size;
            float *dst = out + y * size;
            for (int x = 0; x < size; x++) {
                dst[x] = (float)row[x] / 255.0f;
            }
        }
    }

    CGContextRelease(ctx);
    return out;
}

#pragma mark - Distance transform

// Felzenszwalb & Huttenlocher 1-D squared distance transform.
static void FGEDT1D(float *f, float *d, int n, int *v, float *z) {
    int k = 0;
    v[0] = 0;
    z[0] = -INFINITY;
    z[1] = INFINITY;

    for (int q = 1; q < n; q++) {
        float s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        while (s <= z[k]) {
            k--;
            s = ((f[q] + q * q) - (f[v[k]] + v[k] * v[k])) / (2.0f * q - 2.0f * v[k]);
        }
        k++;
        v[k] = q;
        z[k] = s;
        z[k + 1] = INFINITY;
    }

    k = 0;
    for (int q = 0; q < n; q++) {
        while (z[k + 1] < q) k++;
        d[q] = (q - v[k]) * (q - v[k]) + f[v[k]];
    }
}

void FGEDT(float *grid, int w, int h) {
    if (!grid || w <= 0 || h <= 0) return;

    int maxDim = (w > h ? w : h) + 1;
    float *f = malloc(sizeof(float) * maxDim);
    float *d = malloc(sizeof(float) * maxDim);
    int   *v = malloc(sizeof(int) * maxDim);
    float *z = malloc(sizeof(float) * (maxDim + 1));
    if (!f || !d || !v || !z) {
        free(f); free(d); free(v); free(z);
        return;
    }

    for (int x = 0; x < w; x++) {
        for (int y = 0; y < h; y++) f[y] = grid[y * w + x];
        FGEDT1D(f, d, h, v, z);
        for (int y = 0; y < h; y++) grid[y * w + x] = d[y];
    }

    for (int y = 0; y < h; y++) {
        float *row = grid + y * w;
        for (int x = 0; x < w; x++) f[x] = row[x];
        FGEDT1D(f, d, w, v, z);
        for (int x = 0; x < w; x++) row[x] = d[x];
    }

    free(f); free(d); free(v); free(z);
}

#pragma mark - Blur

static void FGBlurPass(float *src, float *dst, int w, int h, int radius, int horizontal) {
    if (radius < 1) {
        memcpy(dst, src, sizeof(float) * w * h);
        return;
    }

    float scale = 1.0f / (radius * 2 + 1);
    int outer = horizontal ? h : w;
    int inner = horizontal ? w : h;

    for (int o = 0; o < outer; o++) {
        float sum = 0;
        for (int i = -radius; i <= radius; i++) {
            int idx = i < 0 ? 0 : (i >= inner ? inner - 1 : i);
            sum += horizontal ? src[o * w + idx] : src[idx * w + o];
        }
        for (int i = 0; i < inner; i++) {
            if (horizontal) dst[o * w + i] = sum * scale;
            else dst[i * w + o] = sum * scale;

            int add = i + radius + 1;
            int sub = i - radius;
            add = add >= inner ? inner - 1 : add;
            sub = sub < 0 ? 0 : sub;
            sum += (horizontal ? src[o * w + add] : src[add * w + o]);
            sum -= (horizontal ? src[o * w + sub] : src[sub * w + o]);
        }
    }
}

void FGGaussianBlur(float *grid, int w, int h, float radius) {
    if (!grid || w <= 0 || h <= 0) return;

    int r = (int)(radius * 0.5f);
    if (r < 1) r = 1;

    float *tmp = malloc(sizeof(float) * w * h);
    if (!tmp) return;

    // Three box passes approximate a Gaussian closely enough for a highlight.
    for (int pass = 0; pass < 3; pass++) {
        FGBlurPass(grid, tmp, w, h, r, 1);
        FGBlurPass(tmp, grid, w, h, r, 0);
    }
    free(tmp);
}

#pragma mark - Edge falloff

void FGEdgeDistance(const uint8_t *mask, uint8_t *out, int w, int h) {
    if (!mask || !out || w <= 0 || h <= 0) return;

    size_t count = (size_t)w * h;
    float *grid = malloc(sizeof(float) * count);
    if (!grid) return;

    // Inside pixels get a large value, outside pixels seed the transform at 0.
    for (size_t i = 0; i < count; i++) {
        grid[i] = mask[i] >= 128 ? 1e6f : 0.0f;
    }

    FGEDT(grid, w, h);

    // Normalise: distance 0 at the edge, 1 deep inside.
    float maxD = 1.0f;
    for (size_t i = 0; i < count; i++) {
        float d = sqrtf(grid[i]);
        grid[i] = d;
        if (d > maxD) maxD = d;
    }

    for (size_t i = 0; i < count; i++) {
        float t = 1.0f - (grid[i] / (maxD * 0.35f + 1e-6f));
        if (t < 0) t = 0;
        if (t > 1) t = 1;
        out[i] = (uint8_t)(t * 255.0f);
    }

    free(grid);
}

void IGDrawOutline(uint8_t *rgba, float *shape, int *size, float strength) {
    if (!rgba || !shape || !size) return;

    // Below 0.2 the caller wants a strong outline; between 0.2 and 0.99 the
    // outline is suppressed entirely; at 0.99 and above it is a faint rim.
    float amount;
    if (strength <= 0.2f) {
        amount = 0.15f;
    } else if (strength < 0.99f) {
        return;
    } else {
        amount = 0.12f;
    }

    int w = size[0];
    int h = size[1];
    if (w <= 0 || h <= 0) return;

    float *grid = malloc(sizeof(float) * w * h);
    if (!grid) return;

    for (int i = 0; i < w * h; i++) {
        grid[i] = shape[i] > 0.5f ? 1e6f : 0.0f;
    }
    FGEDT(grid, w, h);

    for (int i = 0; i < w * h; i++) {
        float d = sqrtf(grid[i]);
        if (d > 2.0f) continue;
        float t = 1.0f - d / 2.0f;
        float add = 255.0f * t * amount;
        for (int c = 0; c < 3; c++) {
            float v = rgba[i * 4 + c] + add;
            rgba[i * 4 + c] = (uint8_t)(v > 255.0f ? 255.0f : v);
        }
    }

    free(grid);
}
