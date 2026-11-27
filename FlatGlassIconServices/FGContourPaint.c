// FlatGlass contour paint. The sign of the seed mask and the units of the
// distance transform are explicit here: non-silhouette seeds have squared
// distance zero. No process-global scratch space or full-icon color overlay.
#include "FGContourPaint.h"
#include "FGRenderPolicy.h"
#include <stdlib.h>

static inline float unit(float x) { return fminf(1.0f, fmaxf(0.0f, x)); }

// Paint only the visible intersection of the artwork and icon silhouette.
// On normal opaque square artwork this is simply the Apple icon silhouette.
static inline float silhouette(const float *alpha, const float *shape, size_t i) {
    const float a = alpha ? unit(alpha[i]) : 1.0f;
    return shape ? fminf(a, unit(shape[i])) : a;
}

// Exact squared Euclidean distance to pixels outside the contour. A one-pixel
// frame is sufficient: for an interior query, no more distant exterior pixel
// beyond this frame can be the nearest one. This also handles a full bitmap.
static bool exterior_distance(float *field, int n, const float *alpha, const float *shape) {
    const int s = n + 2;
    int *sites = malloc((size_t)s * sizeof(*sites));
    double *cuts = malloc((size_t)(s + 1) * sizeof(*cuts));
    float *row = malloc((size_t)s * sizeof(*row));
    if (!sites || !cuts || !row) { free(sites); free(cuts); free(row); return false; }

    // Vertical squared distance to the nearest outside sample in the column.
    for (int x = 0; x < s; ++x) {
        int previous = 0;
        for (int y = 0; y < s; ++y) {
            bool outside = !x || !y || x == s - 1 || y == s - 1;
            if (!outside) outside = silhouette(alpha, shape, (size_t)(y-1)*n+(x-1)) < 0.5f;
            if (outside) previous = y;
            const int dy = y - previous;
            field[(size_t)y*s+x] = (float)(dy*dy);
        }
        int next = s-1;
        for (int y = s-1; y >= 0; --y) {
            float *v = &field[(size_t)y*s+x];
            if (*v == 0.0f) next = y;
            const int dy = next - y;
            *v = fminf(*v, (float)(dy*dy));
        }
    }
    // Lower envelope of parabolas row[q] + (x-q)^2. All columns have an
    // exterior seed (the padding), so no infinity subtraction is possible.
    for (int y = 1; y <= n; ++y) {
        float *dst = field + (size_t)y*s;
        for (int x = 0; x < s; ++x) row[x] = dst[x];
        int k = 0; sites[0] = 0; cuts[0] = -INFINITY; cuts[1] = INFINITY;
        for (int q = 1; q < s; ++q) {
            double split;
            for (;;) {
                const int p = sites[k];
                split = ((double)row[q]+q*q-((double)row[p]+p*p)) / (2.0*(q-p));
                if (!k || split > cuts[k]) break;
                --k;
            }
            ++k; sites[k] = q; cuts[k] = split; cuts[k+1] = INFINITY;
        }
        k = 0;
        for (int x = 0; x < s; ++x) {
            while (cuts[k+1] < x) ++k;
            const int p = sites[k], dx = x-p;
            dst[x] = row[p] + (float)(dx*dx);
        }
    }
    free(sites); free(cuts); free(row);
    return true;
}

// The two original light lobes (kP1/kP2), symmetric over the 32-sample ring.
static float light_lobe(float turns, const float *half, int end) {
    float t = turns-floorf(turns);
    float idx = 32.0f * fminf(t, 1.0f-t);
    if (idx >= (float)end) return 0.0f;
    int i = (int)idx;
    return half[i] + (idx-(float)i)*(half[i+1]-half[i]);
}

bool FGPaintContour(float *rgb, const float *coverage, const float *shape, int n,
                    bool chiclet, bool outline, float style) {
    if (!rgb || n <= 0 || n > FG_MAX_PIXELS) return false;
    const bool white = style <= 0.2f;
    outline = outline && (white || style >= 0.99f);
    if (!chiclet && !outline) return true;
    const int s = n+2;
    float *field = malloc((size_t)s*s*sizeof(*field));
    if (!field) return false;
    if (!exterior_distance(field, n, coverage, shape)) { free(field); return false; }
    const float brightBand = 22.0f*(float)n/1024.0f;
    const float halfW = (float)n/768.0f;
    // Clipped pixel area for a sub-pixel stroke at the inside boundary.
    // Linear AA at one pixel: even a 120px icon has a nonzero outer row.
    const float gain = white ? 0.15f : 0.12f;
    const float target = white ? 1.0f : 0.0f;
    const float center = 0.5f*((float)n-1.0f);
    static const float p1[] = {1,.9757f,.9039f,.7872f,.6302f,.4389f,.2206f,0};
    static const float p2[] = {1,.9667f,.8682f,.7081f,.4927f,.2303f,0};
    const float invTau = 0.15915494309189535f;
    for (int y=0; y<n; ++y) for (int x=0; x<n; ++x) {
        const size_t i = (size_t)y*n+x;
        const float a = silhouette(coverage, shape, i);
        if (a <= 0.0f) continue;
        // Inside: distance between sample centres minus half a pixel, with
        // fractional coverage shifting the contour towards the sample centre.
        const float d2 = field[(size_t)(y+1)*s+x+1];
        const float depth = fmaxf(0.0f, sqrtf(d2) - 1.5f + a);
        const float highlight = chiclet ? unit(1.0f-depth/brightBand) : 0.0f;
        const float stroke = outline ? unit(halfW+0.5f-depth) : 0.0f;
        if (highlight <= 0 && stroke <= 0) continue;
        float *p = rgb+3*i;
        if (highlight > 0) {
            const float phase = atan2f((float)y-center, (float)x-center)*invTau;
            const float fa = light_lobe(phase+0.375f,p1,7);
            const float fb = light_lobe(phase-0.125f,p2,6);
            const float h = highlight*a;
            const float mix = 1.0f-(1.0f-0.6f*h*fa)*(1.0f-0.4f*h*fb);
            for (int k=0; k<3; ++k) {
                float base = unit(p[k]+0.0796f*h);
                p[k] = unit(base+(1.1f-base)*mix);
            }
        }
        if (stroke > 0) {
            const float w = gain*stroke*a;
            for (int k=0; k<3; ++k) p[k] += (target-p[k])*w;
        }
    }
    free(field);
    return true;
}

void FGDrawOutline(float *rgb, const float *coverage, const float *shape,
                   int n, float style, float unusedStrength) {
    (void)unusedStrength;
    if (shape) (void)FGPaintContour(rgb, coverage, shape, n, false, true, style);
}

void FGDrawChicletHighlights(float *rgb, const float *shape, int n) {
    (void)FGPaintContour(rgb, NULL, shape, n, true, false, 0.1f);
}
