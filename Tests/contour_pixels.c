/* Host regression for the packaged paint operators (not a reference renderer). */
#include "FGContourPaint.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum Fixture { HARD, AA, FULL, ALPHA_HOLE, SHAPE_HOLE, CLEAR };
enum Op { WHITE, HIGHLIGHT, BLACK, OFF };
static const char *const fixtures[] = {"hard", "AA", "full", "aHole", "sHole", "clear"};
static const char *const ops[] = {"white", "highlight", "black", "off"};
static const float gray = 0.4f;

/* Known input geometry, independent of the implementation's distance transform.
 * Positive depth = inside. A full canvas ends half a pixel past its last center. */
static float depth(enum Fixture f, int n, int x, int y, float *hole_depth) {
    const float mid = (n - 1) * 0.5f;
    const float dx = fabsf(x - mid), dy = fabsf(y - mid);
    const float frame = n * 0.5f - fmaxf(dx, dy);
    *hole_depth = n;
    if (f == ALPHA_HOLE || f == SHAPE_HOLE) {
        *hole_depth = hypotf(x - 0.28f*n, y - 0.30f*n) - 0.10f*n;
        return fminf(frame, *hole_depth);
    }
    if (f == FULL) return frame;
    if (f == CLEAR) return -n;
    /* Same rounded square and analytic AA ramp as the test1 pixel probe. */
    const float radius = 0.20f*n, outer = 0.47f*n;
    const float qx = dx - (outer - radius), qy = dy - (outer - radius);
    return -(hypotf(fmaxf(qx, 0), fmaxf(qy, 0)) + fminf(fmaxf(qx, qy), 0) - radius);
}

static float clamp01(float v) { return fminf(1, fmaxf(0, v)); }
static int byte(float channel, float alpha) {
    return (int)lrintf(clamp01(channel) * clamp01(alpha) * 255.0f);
}

static int probe(int n, enum Fixture f, enum Op op) {
    const size_t count = (size_t)n*n, bytes = count * sizeof(float);
    /* Separate mutable inputs and independent snapshots, even when values agree. */
    float *buf = malloc(7 * bytes);
    if (!buf) { perror("malloc"); exit(2); }
    float *rgb = buf, *a = rgb + 3*count, *s = a + count;
    float *a0 = s + count, *s0 = a0 + count;
    const int clip = f == SHAPE_HOLE;
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        int i = y*n + x;
        float hole, d = depth(f, n, x, y, &hole);
        float mask = f == AA ? clamp01(0.5f + d) : (float)(d >= 0);
        /* Exercise unlike planes: outline must find the hole in shape with
         * fully opaque source; highlight must find it in coverage alone. */
        a[i] = clip ? 1 : mask;
        s[i] = (f == CLEAR || f == ALPHA_HOLE) ? 1 : mask;
        rgb[3*i] = rgb[3*i+1] = rgb[3*i+2] = gray;
    }
    memcpy(a0, a, bytes);
    memcpy(s0, s, bytes);
    if (op == HIGHLIGHT) FGDrawChicletHighlights(rgb, a, n);
    else FGDrawOutline(rgb, a, s, n, op == OFF ? 0.5f : op == BLACK ? 0.99f : 0.1f, 0.0f);

    int changed = 0, edge = 0, inner = 0, opaque = 0, center = 0, deep = 0;
    int clear = 0, max8 = 0, bad_rgb = 0, wrong_sign = 0, tinted = 0, off_write = 0;
    int sum8 = 0;
    int deep_rgb = 0; /* Sub-byte wash must not accumulate on repeated painting. */
    /* Much wider than a 1-pixel line or the nominal 22*n/1024 highlight. */
    const float band = 1.0f + 0.05f*n, mid = (n - 1) * 0.5f;
    for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        int i = y*n + x, delta = 0, first = 0;
        float hole, d = depth(f, n, x, y, &hole);
        /* Like the prior probe, pack with source alpha (not AA alpha squared).
         * Only the shape-driven hole explicitly models a shape-clipped store. */
        float before = a0[i] * (clip ? s0[i] : 1), after = a[i] * (clip ? s[i] : 1);
        int src = byte(gray, before);
        for (int k = 0; k < 3; ++k) {
            float v = rgb[3*i+k];
            if (op == OFF && v != gray) ++off_write;
            if (before == 1 && d > band && fabsf(v-gray) > 1e-6f) ++deep_rgb;
            if (!isfinite(v) || (after > 0 && (v < 0 || v > 1))) { ++bad_rgb; continue; }
            int diff = byte(v, after) - src;
            if ((op == BLACK && diff > 0) || (op != BLACK && diff < 0)) ++wrong_sign;
            if (k == 0) first = diff;
            else if ((op == WHITE || op == BLACK) && diff != first) ++tinted;
            if (abs(diff) > delta) delta = abs(diff);
        }
        if (before == 0 && (delta || byte(1, after) != 0)) ++clear;
        if (!delta) continue;
        ++changed;
        sum8 += delta;
        if (delta > max8) max8 = delta;
        if (before == 1) ++opaque;
        if (before > 0 && fabsf(d) <= band) ++edge;
        if (before > 0 && fabsf(hole) <= band) ++inner;
        if (before == 1 && d > band) ++deep;
        if (fabsf(x-mid) < 0.05f*n && fabsf(y-mid) < 0.05f*n) ++center;
    }
    int mask_write = memcmp(a, a0, bytes) != 0 || memcmp(s, s0, bytes) != 0;
    /* Floors scale with perimeter, not area. Allow sparse directional highlights
     * and different AA/width choices. Caps are loose visible-byte envelopes on
     * this gray only, not transfer functions for arbitrary real artwork. */
    int paint = f != CLEAR && op != OFF;
    /* Chiclet permits local specular peaks, not a white stripe. From gray
     * 102 keep >=32 codes of headroom, and mean lift <=40 on changed pixels. */
    int limit = op == BLACK ? 18 : op == WHITE ? 32 : 255-102-32;
    int ok = !mask_write && !bad_rgb && !wrong_sign && !tinted && !off_write &&
             (op != HIGHLIGHT || sum8 <= 40*changed) && !deep_rgb && !deep && !center && !clear && max8 <= limit &&
             (paint ? edge >= n/2 && max8 >= 2 : changed == 0) &&
             (!paint || (f != SHAPE_HOLE && f != ALPHA_HOLE) || inner >= n/12);
    printf("%3d %-5s %-9s changed8=%d edge=%d max=%d center=%d deep=%d opaque=%d",
           n, fixtures[f], ops[op], changed, edge, max8, center, deep, opaque);
    if (f == SHAPE_HOLE || f == ALPHA_HOLE) printf(" hole=%d", inner);
    if (op == HIGHLIGHT) printf(" mean=%.1f", changed ? (double)sum8/changed : 0.0);
    if (!ok) printf(" FAIL clear=%d maskWrite=%d badRGB=%d sign=%d tint=%d offWrite=%d deepRGB=%d",
                    clear, mask_write, bad_rgb, wrong_sign, tinted, off_write, deep_rgb);
    putchar('\n');
    free(buf);
    return !ok;
}

int main(void) {
    int failed = 0;
    const int sizes[] = {120, 180};
    for (size_t i = 0; i < sizeof sizes / sizeof *sizes; ++i) {
        for (enum Fixture f = HARD; f <= CLEAR; ++f) {
            failed += probe(sizes[i], f, WHITE);
            if (f != SHAPE_HOLE) failed += probe(sizes[i], f, HIGHLIGHT);
            if (f == HARD || f == AA) {
                failed += probe(sizes[i], f, BLACK);
                failed += probe(sizes[i], f, OFF);
            }
        }
    }
    printf("contour pixel regressions: %d failing case(s)\n", failed);
    return failed != 0;
}
