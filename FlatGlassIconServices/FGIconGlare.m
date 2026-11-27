// FlatGlass: CoreGraphics icon silhouette and box/blur helpers.
// Contour distances and paint live in FGContourPaint.c; see D_iconglare.c
// (reference only). Original shape: IGCreateIconShape at arm64 VA 0xddbc.

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

        // Each table is one cubic: control 1, control 2, endpoint.
        static const double (*const curves[])[2] = {c1, c2, c3};
        for (int k = 0; k < 3; k++) {
            const double (*p)[2] = curves[k];
            CGPoint a = CGPointApplyAffineTransform(CGPointMake(p[0][0], p[0][1]), m);
            CGPoint b = CGPointApplyAffineTransform(CGPointMake(p[1][0], p[1][1]), m);
            CGPoint e = CGPointApplyAffineTransform(CGPointMake(p[2][0], p[2][1]), m);
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
