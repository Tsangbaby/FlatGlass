//
//  FGIconGlare.c
//  玻璃/描边用的图像原语。移植自 IconGlare (evgeniy558)。
//
//  原二进制里这些函数是纯 C、SSE→NEON 向量化的，逐指令还原版本见
//  reverse-reference/D_iconglare.c（含地址标注与全部常量）。
//  本文件是**可编译版本**：`FGIconShape` 为逐点精确还原；
//  模糊/描边/高光按原算法结构实现，强度系数待设备对齐（见文件末尾 TODO）。
//
//  地址对照：0xddbc IGCreateIconShape / 0xe320 boxPass / 0xcf50 gaussianBlur
//            0xd568 edt / 0xd9f4 IGDrawOutline / 0xd0d0 IGDrawChicletHighlights
//

#include "FGInternal.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

#pragma mark - 图标形状（Apple squircle，四段三次贝塞尔）

// 原 0xddbc。设计空间 1024×1024，四角各三段三次贝塞尔；四组常量关于 45° 线对称。
float *FGIconShape(int n) {
    if (n <= 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(NULL, n, n, 8, n, cs, 0);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    const double s   = (double)n / 1024.0;
    const double cen = 512.0 * s;

    const double P0 = 671.795593262;
    static const double c1[3][2] = {
        { 773.211242676,   0.0            },
        { 823.919067383,   0.0            },
        { 878.503845215,  17.2595844269   },
    };
    static const double c2[3][2] = {
        { 938.101379395,  38.9513206482   },
        { 985.048706055,  85.8986129761   },
        {1006.740417480, 145.496170044    },
    };
    static const double c3[3][2] = {
        {1024.0,         200.080963135    },
        {1024.0,         250.788772583    },
        {1024.0,         352.204406738    },
    };

    CGMutablePathRef path = CGPathCreateMutable();
    for (int i = 0; i < 4; i++) {
        CGAffineTransform m = CGAffineTransformIdentity;
        m = CGAffineTransformTranslate(m, cen, cen);
        m = CGAffineTransformRotate(m, (double)i * 1.5707963267948966);
        m = CGAffineTransformTranslate(m, -cen, -cen);
        m = CGAffineTransformScale(m, s, s);

        CGPoint p0 = CGPointApplyAffineTransform(CGPointMake(P0, 0.0), m);
        if (i == 0) CGPathMoveToPoint(path, NULL, p0.x, p0.y);
        else        CGPathAddLineToPoint(path, NULL, p0.x, p0.y);

        for (int k = 0; k < 3; k++) {
            CGPoint a = CGPointApplyAffineTransform(CGPointMake(c1[k][0], c1[k][1]), m);
            CGPoint b = CGPointApplyAffineTransform(CGPointMake(c2[k][0], c2[k][1]), m);
            CGPoint e = CGPointApplyAffineTransform(CGPointMake(c3[k][0], c3[k][1]), m);
            CGPathAddCurveToPoint(path, NULL, a.x, a.y, b.x, b.y, e.x, e.y);
        }
    }
    CGPathCloseSubpath(path);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);

    const unsigned char *data = CGBitmapContextGetData(ctx);
    float *out = malloc((size_t)n * n * sizeof(float));
    if (out) {
        for (int y = 0; y < n; y++) {            // CG 原点在左下 → 行序翻转
            const unsigned char *src = data + (size_t)(n - 1 - y) * n;
            float *dst = out + (size_t)y * n;
            for (int x = 0; x < n; x++) dst[x] = (float)src[x] / 255.0f;
        }
    }
    CGContextRelease(ctx);
    return out;
}

#pragma mark - 盒式模糊

// 原 0xe320。滑窗求和 + 归一化，越界样本按 0 计（不是 clamp，所以贴边会变暗）。
void FGBoxPass(float *plane, float *row, int n, int r, int dir) {
    if (r < 1 || n < 1) return;
    const float inv = 1.0f / (float)(2 * r + 1);
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++)
            row[j] = dir ? plane[(size_t)i * n + j] : plane[(size_t)j * n + i];

        float sum = 0.0f;
        for (int k = 0; k <= r && k < n; k++) sum += row[k];
        for (int j = 0; j < n; j++) {
            int add = j + r, sub = j - r - 1;
            plane[dir ? (size_t)i * n + j : (size_t)j * n + i] = sum * inv;
            if (add < n) sum += row[add];
            if (sub >= 0) sum -= row[sub];
        }
    }
}

// 原 0xcf50。Kutskir 三趟盒式近似（与 σ 对应的三个不同半径），固定 3 趟，与 IG_STEPS 无关。
void FGGaussianBlur(float *plane, int n, float sigma) {
    if (!plane || n < 1 || sigma <= 0.0f) return;

    float *row = malloc((size_t)n * sizeof(float));
    if (!row) return;

    // wIdeal = floor(sqrt(12σ²/3 + 1))；wu 取偶、wl = wu - 1 取奇
    int wi = (int)floor(sqrt(12.0f * sigma * sigma / 3.0f + 1.0f));
    int wu = wi + (wi & 1);
    int wl = wu - 1;
    int m  = (int)lrintf((3.0f * wl * wl - 12.0f * sigma * sigma - 12.0f * wl - 9.0f)
                         / (-4.0f * wl - 4.0f));

    for (int i = 0; i < 3; i++) {
        int r = ((m > i) ? wl - 1 : wu) / 2;
        if (r < 1) continue;
        FGBoxPass(plane, row, n, r, 1);
        FGBoxPass(plane, row, n, r, 0);
    }
    free(row);
}

#pragma mark - 欧氏距离变换

// 原 0xd568。两趟 chamfer 近似（3-4 距离），足够做 1~4 px 带宽的描边。
void FGEdt(const uint8_t *mask, int n, float *dist, int *nearCol, int *nearRow) {
    const float INF = 1e9f;
    for (int i = 0; i < n * n; i++) {
        if (mask[i]) { dist[i] = 0.0f; nearCol[i] = i % n; nearRow[i] = i / n; }
        else         { dist[i] = INF;  nearCol[i] = -1;     nearRow[i] = -1; }
    }

    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            size_t i = (size_t)y * n + x;
            if (dist[i] == 0) continue;
            if (x > 0     && dist[i - 1] + 1.0f < dist[i]) { dist[i] = dist[i - 1] + 1.0f; nearCol[i] = nearCol[i - 1]; nearRow[i] = nearRow[i - 1]; }
            if (y > 0     && dist[i - n] + 1.0f < dist[i]) { dist[i] = dist[i - n] + 1.0f; nearCol[i] = nearCol[i - n]; nearRow[i] = nearRow[i - n]; }
            if (x > 0 && y > 0 && dist[i - n - 1] + 1.4142f < dist[i]) { dist[i] = dist[i - n - 1] + 1.4142f; nearCol[i] = nearCol[i - n - 1]; nearRow[i] = nearRow[i - n - 1]; }
            if (x + 1 < n && y > 0 && dist[i - n + 1] + 1.4142f < dist[i]) { dist[i] = dist[i - n + 1] + 1.4142f; nearCol[i] = nearCol[i - n + 1]; nearRow[i] = nearRow[i - n + 1]; }
        }
    }
    for (int y = n - 1; y >= 0; y--) {
        for (int x = n - 1; x >= 0; x--) {
            size_t i = (size_t)y * n + x;
            if (dist[i] == 0) continue;
            if (x + 1 < n  && dist[i + 1] + 1.0f < dist[i]) { dist[i] = dist[i + 1] + 1.0f; nearCol[i] = nearCol[i + 1]; nearRow[i] = nearRow[i + 1]; }
            if (y + 1 < n  && dist[i + n] + 1.0f < dist[i]) { dist[i] = dist[i + n] + 1.0f; nearCol[i] = nearCol[i + n]; nearRow[i] = nearRow[i + n]; }
            if (x + 1 < n && y + 1 < n && dist[i + n + 1] + 1.4142f < dist[i]) { dist[i] = dist[i + n + 1] + 1.4142f; nearCol[i] = nearCol[i + n + 1]; nearRow[i] = nearRow[i + n + 1]; }
            if (x > 0 && y + 1 < n && dist[i + n - 1] + 1.4142f < dist[i]) { dist[i] = dist[i + n - 1] + 1.4142f; nearCol[i] = nearCol[i + n - 1]; nearRow[i] = nearRow[i + n - 1]; }
        }
    }
}

#pragma mark - 描边

// 原 0xd9f4。
//
//   style 落在 (0.2, 0.99) 之间 -> 直接 return（没有描边）
//   style <= 0.2  -> 白色描边，增益 0.15
//   style >= 0.99 -> 黑色描边，增益 0.12
//   半宽 w = (n/1024) * 2.6667 * 0.5 = n/768        （1024 时 1.333，实际线宽≈2.67px）
//   覆盖度 cov = clamp01(w - |sdf + 0.5 - alpha| + 0.5)
//
//   sdf：形状内部取 -(sqrt(d_toOutside)-0.5)，外部取 +(sqrt(d_toInside)-0.5)
void FGDrawOutline(float *rgb, const float *coverage, const float *shape,
                   int n, float style, float unusedStrength) {
    (void)unusedStrength;
    if (!rgb || !shape || n <= 0) return;
    if (style > 0.2f && style < 0.99f) return;

    const float target = (style <= 0.2f) ? 1.0f : 0.0f;      // 白 / 黑
    const float gain   = (style <= 0.2f) ? 0.15f : 0.12f;
    const float halfW  = (float)n / 768.0f;

    uint8_t *maskOut = malloc((size_t)n * n);                 // 1 = 形状外
    uint8_t *maskIn  = malloc((size_t)n * n);                 // 1 = 形状内
    float   *dOut    = malloc((size_t)n * n * sizeof(float));
    float   *dIn     = malloc((size_t)n * n * sizeof(float));
    int     *nc      = malloc((size_t)n * n * sizeof(int));
    int     *nr      = malloc((size_t)n * n * sizeof(int));
    if (!maskOut || !maskIn || !dOut || !dIn || !nc || !nr) goto cleanup;

    for (int i = 0; i < n * n; i++) {
        BOOL inside = shape[i] >= 0.5f;
        maskIn[i]  = inside ? 0 : 1;
        maskOut[i] = inside ? 1 : 0;
    }
    FGEdt(maskOut, n, dOut, nc, nr);      // 每个内部像素到"外部"的距离
    FGEdt(maskIn,  n, dIn,  nc, nr);      // 每个外部像素到"内部"的距离

    for (int i = 0; i < n * n; i++) {
        BOOL inside = shape[i] >= 0.5f;
        float d = inside ? (sqrtf(dOut[i]) - 0.5f) : -(sqrtf(dIn[i]) - 0.5f);
        float a = coverage ? coverage[i] : 1.0f;
        float cov = halfW - fabsf(d + 0.5f - a) + 0.5f;
        if (cov <= 0.0f) continue;
        if (cov > 1.0f) cov = 1.0f;

        float *p = rgb + (size_t)i * 3;
        float w = cov * gain;
        p[0] += (target - p[0]) * w;
        p[1] += (target - p[1]) * w;
        p[2] += (target - p[2]) * w;
    }

cleanup:
    free(maskOut); free(maskIn); free(dOut); free(dIn); free(nc); free(nr);
}

#pragma mark - Chiclet 高光

// 原 0xd0d0。
//
//   两个相隔 180° 的斜向方位窗：kP1 宽 7/32 圈（78.75°）、kP2 宽 6/32 圈（67.5°），
//   查表 32 级线性插值；相位 (θ+3π/4)/2π 与 (θ−π/4)/2π。
//   带宽 band = 22 * n / 1024。
//   覆盖度 cov = clamp01(1 - (sqrt(d) - 0.5 + alpha - 0.5) / band)
//   合成      : c' = min(1, min(1, c + 0.0796*cov) * (1-a) + 1.1*a)
//               （0.0796 = 1/4π，1.1 为过曝系数）
void FGDrawChicletHighlights(float *rgb, const float *coverage, int n) {
    if (!rgb || n <= 0) return;

    const float band = 22.0f * (float)n / 1024.0f;
    if (band <= 0.0f) return;

    // kP1 / kP2：32 级余弦窗，两路相位相差 180°
    float lut1[32], lut2[32];
    for (int i = 0; i < 32; i++) {
        float ph = (float)i / 32.0f;
        float a1 = 7.0f / 32.0f, a2 = 6.0f / 32.0f;
        lut1[i] = fmaxf(0.0f, cosf((ph - 0.5f) * 6.2831853f / a1) * 0.5f + 0.5f);
        lut2[i] = fmaxf(0.0f, cosf((ph - 0.5f) * 6.2831853f / a2) * 0.5f + 0.5f);
    }

    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            size_t i = (size_t)y * n + x;
            float a = coverage ? coverage[i] : 1.0f;
            if (a <= 0.0f) continue;

            // 以中心为原点的极角
            float dx = (float)x - (float)(n - 1) * 0.5f;
            float dy = (float)y - (float)(n - 1) * 0.5f;
            float theta = atan2f(dy, dx);
            float ph1 = fmodf(theta + 2.3561945f, 6.2831853f) / 6.2831853f;  // +3π/4
            float ph2 = fmodf(theta - 0.7853982f, 6.2831853f) / 6.2831853f;  // −π/4
            if (ph1 < 0) ph1 += 1.0f;
            if (ph2 < 0) ph2 += 1.0f;

            int idx1 = (int)(ph1 * 32.0f) & 31;
            int idx2 = (int)(ph2 * 32.0f) & 31;
            float win = fmaxf(lut1[idx1], lut2[idx2]);
            if (win <= 0.0f) continue;

            float d = (float)(dx * dx + dy * dy);
            float t = (sqrtf(d) - 0.5f + a - 0.5f) / band;
            float cov = 1.0f - t;
            if (cov <= 0.0f) continue;
            if (cov > 1.0f) cov = 1.0f;

            float *p = rgb + i * 3;
            for (int k = 0; k < 3; k++) {
                float c = p[k] + 0.0796f * cov * win;
                if (c > 1.0f) c = 1.0f;
                float v = c * (1.0f - a) + 1.1f * a;
                p[k] = (v > 1.0f) ? 1.0f : v;
            }
        }
    }
}

// 说明：chiclet 窗口的查表（kP1/kP2）与 IG_STEPS 位开关相关（bit1/bit2 各控一路），
// 这里取两路的最大值，等价于两路全开（IG_STEPS 缺省 1503 即如此）。
// 逐指令版本见 reverse-reference/D_iconglare.c 的 IGDrawChicletHighlights。
