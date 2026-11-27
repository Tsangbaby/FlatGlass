
/* ============================================================================
 * FlatGlassIconServices.dylib —— 图像处理原语还原 (arm64 iOS, strip 但保留函数名)
 *
 * 本文件是对以下 10 个函数的反汇编还原（地址即 __text 内偏移），不保证可直接编译，
 * 目标是"语义等价 + 常量/边界/步长完整"。原工程: IconGlare (evgeniy558) 的移植。
 *
 *   0xbdd0 OUTLINED_FUNCTION_0   0xbde4 blurPlane    0xbde8 IGGaussianBlurPublic
 *   0xbdec IGDrawGroup           0xcf50 gaussianBlur 0xd0d0 IGDrawChicletHighlights
 *   0xd568 edt                   0xd9f4 IGDrawOutline 0xddbc IGCreateIconShape
 *   0xe320 boxPass
 *
 * 全局约定（由全部函数共同印证）：
 *   - 位图为 n x n 正方形(边长 n = 16..1024)，n 保存在上下文结构体 +0 处。
 *   - "像素平面"有两种形态：
 *       (a) alpha/单通道 float 平面：1 个 float/像素，行距 4n 字节；
 *       (b) 输出 RGB float 平面：3 个 float/像素 (R,G,B)，行距 12n 字节，
 *           指针在上下文 +8 处。
 *   - 大量算法在四周扩边（border=2 / 4 / 8）后进行，因此内部数组尺寸多为 (n+k)^2。
 *   - 环境变量 IG_STEPS：getenv("IG_STEPS") -> atol()，缺省 1503 (0x5DF)，
 *     被当作 **位掩码** 使用（不是步数）：
 *        bit0/1/2/3 见 IGDrawChicletHighlights (bit1、bit2 分别开关两项高光)
 *        bit4  IGDrawGroup: 是否做 expf 衰减的高光项
 *        bit6  IGDrawGroup: 是否做环境/边缘光合成
 *        bit7  IGDrawGroup: 总开关；若为 0 则强制 opt->i08 = 0（关掉影子块）
 *        bit8  IGDrawGroup: 是否做"锐化/镜面"分支
 *        缺省 1503 = 0b101_1101_1111 -> bit0,1,2,3,4,6,7,8,10 置位
 *   - 全局 1 字节 gGlassNoEdge (0x18d68) 本批函数未引用。
 * ==========================================================================*/

/* 上下文描述符：只用到 +0 与 +8（其余字段本批函数未触碰） */
typedef struct IGCtx {
    int     size;      /* +0x00 : n，位图边长 (px) */
    int     pad04;     /* +0x04 : 未使用 */
    float  *rgb;       /* +0x08 : 目标平面, 3 float/像素，行距 12n 字节 */
} IGCtx;

/* IGDrawGroup 的选项块（偏移由 [x21,#0]/#4/#5/#8/#0xc/#0x10 反推） */
typedef struct IGOpts {
    float   amount;    /* +0x00 : 0..1 强度 */
    unsigned char b04; /* +0x04 : ==1 才做 rim/斜面通道 */
    unsigned char b05; /* +0x05 : bit0 走"法线/SDF 光照"通道 */
    unsigned char pad06, pad07;
    int     shadowOn;  /* +0x08 : 影子开关(被 IG_STEPS bit7 强制清零) */
    float   shadow;    /* +0x0c : 影子强度 */
    unsigned char b10; /* +0x10 : 0/1，选择高光增益系数 */
} IGOpts;

#define CLAMP01(x)  ((x) < 0.0f ? 0.0f : ((x) > 1.0f ? 1.0f : (x)))
#define INF_F       1.0e20f

/* x - trunc(x)，负数补 1（对应 frintz + fcsel 的那两段） */
static inline float frac01(float x)
{
    float f = x - truncf(x);
    return (f < 0.0f) ? f + 1.0f : f;
}


// @addr 0xbdd0 OUTLINED_FUNCTION_0

/* ==========================================================================
 * @addr 0xbdd0  OUTLINED_FUNCTION_0
 *   编译器生成的 "冷路径" 片段：只是 _dispatch_once 的调用点（不属于任何具名
 *   API，是被优化器拆出来的 out-of-line 块）。等价于:
 *       dispatch_once(&_extSRGB.once, &__block_literal_global);
 *   参数: x0 = &_extSRGB.once (0x18d78), x1 = &__block_literal_global (0x140e0)
 * ==========================================================================*/
void OUTLINED_FUNCTION_0(void)
{
    /* x0 = 0x18d78 (_extSRGB.once), x1 = 0x140e0 (__block_literal_global) */
    dispatch_once((dispatch_once_t *)0x18d78, (void *)0x140e0);
}


// @addr 0xbde4 blurPlane
// @addr 0xbde8 IGGaussianBlurPublic

/* ==========================================================================
 * @addr 0xbde4  blurPlane        —— 纯 thunk，直接 b _gaussianBlur
 * @addr 0xbde8  IGGaussianBlurPublic —— 同上（对外导出的别名）
 *   两个符号都是 `b 0xcf50`，签名与 gaussianBlur 完全一致。
 * ==========================================================================*/
void blurPlane(float *plane, int n, float sigma)          { gaussianBlur(plane, n, sigma); }
void IGGaussianBlurPublic(float *plane, int n, float sigma){ gaussianBlur(plane, n, sigma); }


// @addr 0xbdec IGDrawGroup

/* ==========================================================================
 * @addr 0xbdec  IGDrawGroup   (0xbdec..0xcf50, 0x1164 字节，本批最大)
 *
 * 把"玻璃"整层合成到 ctx->rgb (3 float/像素)：
 *   块 A 影子/暗边  (opt->shadowOn != 0 && opt->shadow > 0)
 *   块 B SDF + 法线 (opt->b05 == 1)
 *   块 C 梯度幅值   (opt->b05 & 1)
 *   块 D 渐变/镜面合成 + 最终叠加
 * 入口:
 *   x0 = ctx, x1 = plane3 (另一张 3float/像素 平面, 只读), x2 = alpha (1float/像素),
 *   x3 = opt
 * ==========================================================================*/
void IGDrawGroup(IGCtx *ctx, float *plane3, float *alpha, IGOpts *opt)
{
    int    n      = ctx->size;            /* ldrsw x22,[x0] */
    size_t npix   = (size_t)n * n;        /* smull x19, w22, w22 */
    float *dst    = ctx->rgb;             /* ldr x20,[x0,#8] */

    /* ---- IG_STEPS ---- */
    long steps;
    {
        char *e = getenv("IG_STEPS");
        if (e) {
            steps = atol(e);
            if (!(steps & 0x80))          /* tbnz w0,#7 -> 跳过清零 */
                opt->shadowOn = 0;        /* str wzr,[x21,#8] */
        } else {
            steps = 1503;                 /* mov w0,#0x5df */
        }
    }
    const float s31 = (float)n / 1024.0f; /* scvtf s31,w22,#0xa —— 全函数的"归一化尺度" */

    /* ---------------- 块 A：模糊影子（自左下方向偏移的暗边） ---------------- */
    if (opt->shadowOn != 0 && opt->shadow > 0.0f) {
        float *buf = calloc(npix, 4);                 /* calloc(n*n, 4) */
        int    r   = (int)roundf(16.0f * s31);        /* r = round(16*n/1024) */

        /* 把 alpha 平面整体平移 (+r, +r) 后拷进 buf；
         * 仅当 r < n 时执行，源行 [0, n-r)、列 [0, n-r) 有效 */
        if (n > r) {
            for (int y = r; y < n; y++)               /* x2: r .. n-1 */
                for (int x = 0; x < n - r; x++)       /* i: 0 .. n-r-1 */
                    buf[y * n + r + x] = alpha[(y - r) * n + x];
        }
        gaussianBlur(buf, n, 20.0f * s31);            /* sigma = 20*n/1024 */

        /* dst.rgb = max(dst.rgb + buf * (-0.1*opt->shadow), 0) */
        float k = opt->shadow * (-0.1f);              /* 0xbdcccccd = -0.1 */
        for (size_t i = 0; i < npix; i++) {
            dst[i * 3 + 0] = fmaxf(dst[i * 3 + 0] + buf[i] * k, 0.0f);
            dst[i * 3 + 1] = fmaxf(dst[i * 3 + 1] + buf[i] * k, 0.0f);
            dst[i * 3 + 2] = fmaxf(dst[i * 3 + 2] + buf[i] * k, 0.0f);
        }
        free(buf);
    }

    /* ---------------- 块 B：双边 mask -> 两次 EDT -> SDF + 法线 ------------- */
    float *planeA = NULL, *planeB = NULL, *planeC = NULL, *planeD = NULL, *planeE = NULL;
    float *distIn = NULL, *distOut = NULL;
    int   *idxIn  = NULL, *idxOut  = NULL;

    if (opt->b05 == 1) {
        /* 5 张 n*n 的 float 平面 */
        planeA = malloc(npix * 4);   /* [sp+0x68]，后面当"梯度/距离"用 */
        planeB = malloc(npix * 4);   /* [sp+0x40] */
        planeC = malloc(npix * 4);   /* [sp+0x48] */
        planeD = malloc(npix * 4);   /* [sp+0x10] */
        planeE = malloc(npix * 4);   /* x27 */

        /* 扩边 2 的 mask，(n+4)^2 */
        const int S = n + 4;                    /* x26 */
        unsigned char *mIn  = calloc((size_t)S * S, 1);   /* x24 */
        unsigned char *mOut = calloc((size_t)S * S, 1);   /* x25 */
        for (int y = 0; y < S; y++) {
            /* 前 2 列固定: mIn=0, mOut=1（图外视为"外部"） */
            mIn [y * S + 0] = 0; mOut[y * S + 0] = 1;
            mIn [y * S + 1] = 0; mOut[y * S + 1] = 1;
            for (int x = 2; x < S; x++) {
                int inside = 0;
                if (y >= 2 && x < n + 2 && (y - 2) < n)      /* 落在真实图内 */
                    inside = (alpha[(y - 2) * n + (x - 2)] >= 0.5f);
                mIn [y * S + x] = (unsigned char)inside;
                mOut[y * S + x] = (unsigned char)(inside ^ 1);
            }
        }

        /* 6 张 (n+4)^2 float 平面 = 2 组 EDT 输出 (dist / 最近点列 / 最近点行) */
        float *dIn  = malloc((size_t)S * S * 4);      /* [sp+0x60] */
        float *dOut = malloc((size_t)S * S * 4);      /* [sp+0x58] */
        float *t1   = malloc((size_t)S * S * 4);      /* [sp+0x50] = 最近列(内) */
        float *t2   = malloc((size_t)S * S * 4);      /* x21 = 最近行(内) */
        float *t3   = malloc((size_t)S * S * 4);      /* x19 = 最近列(外) */
        float *t4   = malloc((size_t)S * S * 4);      /* x20 = 最近行(外) */

        edt(mIn,  S, dIn,  (int *)t1, (int *)t2);
        edt(mOut, S, dOut, (int *)t3, (int *)t4);
        distIn = dIn; distOut = dOut; idxIn = (int *)t1; idxOut = (int *)t3;

        /* 逐像素：有符号距离 + 归一化法线
         * 内: sdf = -(sqrt(dist 到最近"外"点) - 0.5)   外: sdf = +(sqrt(dist 到最近"内"点) - 0.5)
         * 法线方向 = -(p - nearestSeed)，然后归一化（直接用 EDT 给出的最近种子点，
         * 而不是差分，所以法线是"指向最近边界点的方向"）
         * 三张输出平面: planeB = nx, planeC = ny, planeD = sdf。
         * TODO(未确定): 三张平面的寄存器复用极乱，此处按语义命名。            */
        for (int y = 0; y < n; y++) {
            for (int x = 0; x < n; x++) {
                int   i  = (y + 2) * S + (x + 2);       /* 扩边 2 之后的索引 */
                float nx, ny, d;
                if (mIn[i]) {
                    /* 内部像素：到最近"外部"像素的距离 */
                    d  = -(sqrtf(dOut[i]) - 0.5f);
                    int cx = idxOut[i];                 /* 最近"外部"点的列 */
                    nx = -((float)(x + 2) - (float)cx);
                    ny = -((float)(y + 2) - (float)t4[i]);
                } else {
                    /* 外部像素：到最近"内部"像素的距离 */
                    d  =  sqrtf(dIn[i]) - 0.5f;
                    int cx = idxIn[i];
                    nx = -((float)(x + 2) - (float)cx);
                    ny = -((float)(y + 2) - (float)t2[i]);
                }
                /* 退化保护：最近点不存在(-1)时把该像素的梯度清零 */
                int ok = mIn[i] ? (idxOut[i] + 1 > 0) : (idxIn[i] + 1 > 0);
                if (!ok) { nx = 0.0f; ny = 0.0f; d = 0.0f; }

                float len2 = nx * nx + ny * ny;
                if (len2 > 0.0f) { float inv = 1.0f / sqrtf(len2); nx *= inv; ny *= inv; }
                /* 注意: 汇编里这三张平面的基址带 (2S+2) 个 float 的偏移，但行距仍是
                 * n（而不是 S）——分配大小是 n*n，属于原实现的越界隐患，此处照抄语义 */
                planeB[i - (2 * S + 2)] = nx;
                planeC[i - (2 * S + 2)] = ny;
                planeD[i - (2 * S + 2)] = d;
            }
        }
        free(mIn); free(mOut);
        free(dOut); free(t3); free(t4);
        /* dIn/t1/t2 由下面块 C 继续使用 */

        /* ---- 块 C：grad = -planeA / (25.8*n/1024)，再求 |dx|+|dy| 到 planeA ---- */
        if (opt->b05 & 1) {
            float ks = 25.8f * s31;                       /* 0x41ce6666 = 25.8 */
            for (size_t i = 0; i < npix; i++)
                planeE[i] = -planeA[i] / ks;

            /* 前向/后向差分取平均；边界处退化为单侧差分（csinc/csel 的钳位） */
            for (int y = 0; y < n; y++) {
                for (int x = 0; x < n; x++) {
                    int ym = (y - 1 < 0) ? 0 : y - 1;
                    int yp = (y + 1 >= n) ? n - 1 : y + 1;
                    int xm = (x - 1 < 0) ? 0 : x - 1;
                    int xp = (x + 1 >= n) ? n - 1 : x + 1;
                    float dx = (planeE[y * n + xp] - planeE[y * n + xm]) / (float)(xp - xm ? xp - xm : 1);
                    float dy = (planeE[yp * n + x] - planeE[ym * n + x]) / (float)(yp - ym ? yp - ym : 1);
                    planeA[y * n + x] = fabsf(dx) + fabsf(dy);
                }
            }
        }
    }

    /* ---------------- 块 D：渐变/镜面合成 ------------- */
    int havePix = (n > 0);
    if (n > 0) {
        float amt  = opt->amount;                       /* ldr s0,[x21] */
        float ia   = 1.0f - amt;
        float amp  = amt * (-0.8f) + 1.0f;              /* 0xbf4ccccd = -0.8 : 1 - 0.8a */

        /* 找 alpha > 2^-10 (=0.0009765625) 的包围盒 (x0,y0)-(x1,y1)，
         * 找不到则 x0 = -1 之类，随后用 bic/csel 钳到 [0,n-1]。
         * TODO(未确定): 搜索是"每行第一个/最后一个过阈像素"，此处按包围盒写。 */
        int bx0 = 0, bx1 = n - 1, by0 = 0, by1 = n - 1;
        {
            const float thr = 1.0f / 1024.0f;           /* 0x3a800000 */
            int found = 0;
            for (int y = 0; y < n && !found; y++)
                for (int x = 0; x < n; x++)
                    if (alpha[y * n + x] > thr) { bx0 = bx1 = x; by0 = by1 = y; found = 1; break; }
            for (int y = 0; y < n; y++)
                for (int x = 0; x < n; x++)
                    if (alpha[y * n + x] > thr) {
                        if (x < bx0) bx0 = x;
                        if (x > bx1) bx1 = x;
                        if (y > by1) by1 = y;
                    }
        }

        /* 沿包围盒做线性渐变，把 plane3 (3float/px) 与 dst 混合：
         *   t = clamp01((x + 0.5 - bx0) / (bx1 - bx0 + 1))  （纵向同理）
         *   强度 = mix(amt, 1, t)，可选 expf 锐化项（steps bit8 才启用）
         * TODO(未确定): 0xc708..0xc828 的循环把 s0=opt->amount、1-amount、-0.8 三者
         *   组合成两条渐变端点，中间还夹了 expf/除法；此处只保留"沿包围盒线性混合
         *   两个 3float 平面"的形状，系数不可逐指令断言。                     */
        for (int y = 0; y < n; y++) {
            float ty = CLAMP01(((float)y + 0.5f - (float)by0) / (float)(by1 - by0 + 1));
            for (int x = 0; x < n; x++) {
                float tx = CLAMP01(((float)x + 0.5f - (float)bx0) / (float)(bx1 - bx0 + 1));
                float g  = amp * tx + 0.0f;                    /* fmadd s24,s5,s25,s0 */
                float g2 = ia  * tx + 1.0f;
                float t  = g2 - g;
                float *d3 = dst + 3 * ((size_t)y * n + x);
                float *s3 = plane3 + 3 * ((size_t)y * n + x);
                float w  = alpha[y * n + x];
                if (w > 0.0f) {
                    for (int c = 0; c < 3; c++) {
                        float v = s3[c] * w + d3[c] * (1.0f - w);   /* fsub s27,s7,s26 */
                        d3[c] = v;
                    }
                }
                (void)t;
            }
        }

        /* 最终叠加：对每个像素把 planeA(梯度/距离) 累加到 dst，系数受
         *   steps bit6 / bit4 / opt->b10 控制，并带一次 expf 衰减（steps bit4）：
         *   e = expf(-0.5 * planeE[i]^2)                       ; expf
         *   k = 0.15 (b10==0) 或 0.0796 (b10!=0)               ; 0x3e19999a / 0x3da30d70
         *   dst += k * e * clamp01(1 - grad/ (5/6*clamp(g2,2)) )  ...
         * TODO(未确定): 这一段是 6 个常量嵌套 clamp 的合成（0.5/1.01/2.01/0.309/
         *   1.309/0.3/0.2/-0.7071/-1.0），寄存器复用严重，只能给出等价的
         *   数学形状，无法逐指令断言。                                       */
        if ((steps & 0x10) && planeE && planeA) {
            for (size_t i = 0; i < npix; i++) {
                float d = planeE[i];                        /* -曲面/25.8 */
                float e = expf(-0.5f * d * d);
                float k = opt->b10 ? 0.0796f : 0.15f;
                float a = planeA[i];
                float t = CLAMP01(a * 0.5f * 0.309f + 1.309f - 1.0f);
                dst[i * 3 + 0] += k * e * t;
                dst[i * 3 + 1] += k * e * t;
                dst[i * 3 + 2] += k * e * t;
            }
        }
        if ((steps & 0x40) && planeD) {
            for (size_t i = 0; i < npix; i++) {
                float v = planeD ? planeD[i] : planeA[i];
                float t = CLAMP01(v * 0.2f + 0.0f);         /* 0x3e4ccccd = 0.2 */
                dst[i * 3 + 0] = fminf(dst[i * 3 + 0] + t, 1.0f);
                dst[i * 3 + 1] = fminf(dst[i * 3 + 1] + t, 1.0f);
                dst[i * 3 + 2] = fminf(dst[i * 3 + 2] + t, 1.0f);
            }
        }
    }

    free(planeA); free(planeB); free(planeC); free(planeD); free(planeE);
    free(distIn); free(idxIn);
}


// @addr 0xcf50 gaussianBlur

/* ==========================================================================
 * @addr 0xcf50  gaussianBlur   (0xcf50..0xd0d0)
 *   Ivan Kutskir 的 "3 次盒式模糊近似高斯"，就地处理 n x n float 平面。
 *   void gaussianBlur(float *plane, int n, float sigma)
 *   只额外 malloc 一行 n 个 float 作为 boxPass 的行缓冲；返回值为 free 的垃圾。
 * ==========================================================================*/
void gaussianBlur(float *plane, int n, float sigma)
{
    /* wIdeal = floor(sqrt(12*sigma^2/3 + 1)) = floor(sqrt(4*sigma^2+1)) */
    float t   = 12.0f * sigma * sigma / 3.0f + 1.0f;
    int   wi  = (int)floorf(sqrtf(t));
    int   wu  = wi + (wi & 1);        /* 向上取偶数 */
    int   wl  = wu - 1;               /* 奇数下界 */

    /* mIdeal = (12σ²-3wl²-12wl-9)/(-4wl-4)，汇编实际算的是其分子取反后的形式：
     *   (3wl²-12σ²-12wl-9) / (-4wl-4)，四舍五入(fcvtas=round half away)
     * TODO(未确定): 与 Kutskir 原式符号约定不同，但当选出的 w 相同时结果等价；
     *               这里保留汇编原样的算式。                              */
    float mf = (3.0f * wl * wl - 12.0f * sigma * sigma - 12.0f * wl - 9.0f)
             / (-4.0f * wl - 4.0f);
    int   m  = (int)roundf(mf);

    float *tmp = malloc((size_t)n * 4);      /* 行缓冲: n 个 float */

    for (int i = 0; i < 3; i++) {
        /* r = ((m > i) ? (wl-1) : wu) / 2  —— 即 floor(w/2) */
        int r = ((m > i) ? (wl - 1) : wu) / 2;
        boxPass(plane, tmp, n, r, 1);        /* 水平 */
        boxPass(plane, tmp, n, r, 0);        /* 垂直 */
    }
    free(tmp);                               /* 原函数以尾调用 free 结束，返回值无定义 */
}


// @addr 0xd0d0 IGDrawChicletHighlights

/* ==========================================================================
 * @addr 0xd0d0  IGDrawChicletHighlights   (0xd0d0..0xd568)
 *   "chiclet"（玻璃按钮）内缘高光：以 EDT 得到的像素到外边界距离为带宽，
 *   叠加 2 个角度窗（kP1 / kP2，各 32 级查表 + 线性插值）。
 *
 *   void IGDrawChicletHighlights(IGCtx *ctx, const float *alpha)
 *   x0 = ctx, x1 = alpha(1 float/像素)
 * ==========================================================================*/
static const float kP1[33] = {  /* 半宽 7/32 圈 = 78.75° 的余弦窗 */
    1.f, 0.975700021f, 0.903900027f, 0.787199974f, 0.630200028f, 0.438899994f,
    0.220599994f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f,
    0.220599994f, 0.438899994f, 0.630200028f, 0.787199974f, 0.903900027f,
    0.975700021f, 1.f
};
static const float kP2[33] = {  /* 半宽 6/32 圈 = 67.5° 的余弦窗 */
    1.f, 0.966700017f, 0.868200004f, 0.708100021f, 0.492700011f, 0.230299994f,
    0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.f, 0.230299994f, 0.492700011f, 0.708100021f,
    0.868200004f, 0.966700017f, 1.f
};

/* 表查值 + 线性插值：x 为 [0,1) 的归一化相位 */
static float ig_lut32(const float *tab, float x)
{
    int   i = (int)(x * 32.0f);            /* fcvtzs w8, s1, #5 */
    float f = x * 32.0f - (float)i;
    if (i > 31) return 1.0f;
    return tab[i] + (tab[i + 1] - tab[i]) * f;
}

void IGDrawChicletHighlights(IGCtx *ctx, const float *alpha)
{
    int     n  = ctx->size;
    float  *dst = ctx->rgb;
    const int S = n + 8;                                  /* 扩边 4 */

    /* 1) 构造 "外部" mask（alpha < 0.5 记为 1），边界固定为 1 */
    unsigned char *mOut = calloc((size_t)S * S, 1);
    for (int y = 0; y < S; y++) {
        mOut[y * S + 0] = 1; mOut[y * S + 1] = 1; mOut[y * S + 2] = 1; mOut[y * S + 3] = 1;
        for (int x = 4; x < S; x++) {
            int v = 1;
            if (y >= 4 && x < n + 4 && (y - 4) < n)
                v = (alpha[(y - 4) * n + (x - 4)] < 0.5f) ? 1 : 0;
            mOut[y * S + x] = (unsigned char)v;
        }
    }

    /* 2) 距离变换：dist = 到最近"外部"像素的距离（即内深度） */
    float *dist = malloc((size_t)S * S * 4);
    int   *i1   = malloc((size_t)S * S * 4);
    int   *i2   = malloc((size_t)S * S * 4);
    edt(mOut, S, dist, i1, i2);

    /* 3) 逐像素高光 */
    const float band   = 22.0f * (float)n / 1024.0f;   /* 高光带宽 = 22*n/1024 */
    const float cxn    = 0.5f * (float)n;              /* 图像中心 */
    const float TWO_PI = 6.2831855f;                   /* 0x40c90fdb */
    for (int y = 0; y < n; y++) {
        float dy = ((float)y + 0.5f) - cxn;
        for (int x = 0; x < n; x++) {
            float dx = ((float)x + 0.5f) - cxn;
            int   i  = (y + 4) * S + (x + 4);

            /* 覆盖度：从边缘向内衰减；alpha 参与偏移 */
            float d   = sqrtf(dist[i]) - 0.5f;
            float cov = CLAMP01(1.0f - (d + (alpha[y * n + x] - 0.5f)) / band);
            if (cov <= 0.0f) continue;

            /* 角度 -> 两个方位窗 */
            float ang = atan2f(dy, dx);
            float fa  = ig_lut32(kP1, frac01((ang + 2.3553f) / TWO_PI));   /* +3π/4 */
            float fb  = ig_lut32(kP2, frac01((ang - 0.7853982f) / TWO_PI));/* -π/4  */

            /* IG_STEPS 位掩码：bit2 开关窗 a，bit1 开关窗 b（缺省 1503 -> 两者都开）
             * 注意：原实现是**在每个像素的循环体内**调用 getenv()+atol()，
             * 这里保持同样语义（性能极差，但这是原样）。 */
            long steps = 1503;
            {
                char *e = getenv("IG_STEPS");
                if (e) steps = atol(e);
            }

            float wa = (steps & 4) ? (1.0f - cov * 0.6f * fa) : 1.0f;
            float wb = (steps & 2) ? (1.0f - cov * 0.4f * fb) : 1.0f;
            float a  = 1.0f - wa * wb;                  /* 混合权 0..~0.77 */

            float add = (steps & 2) ? cov * 0.0796f : 0.0f;   /* 加性项 1/(4π) */

            float *p = dst + 3 * ((size_t)y * n + x);
            /* p = min(1, min(1, p + add)*(1-a) + 1.1*a)  (1.1 = 0x3f8ccccd) */
            p[0] = fminf((fminf(p[0] + add, 1.0f)) * (1.0f - a) + 1.1f * a, 1.0f);
            p[1] = fminf((fminf(p[1] + add, 1.0f)) * (1.0f - a) + 1.1f * a, 1.0f);
            p[2] = fminf((fminf(p[2] + add, 1.0f)) * (1.0f - a) + 1.1f * a, 1.0f);
        }
    }
    free(mOut); free(dist); free(i1); free(i2);
}


// @addr 0xd568 edt

/* ==========================================================================
 * @addr 0xd568  edt   (0xd568..0xd9f4)   精确欧氏距离变换
 *
 *   void edt(const uint8_t *mask, int n, float *dist, int32_t *nearCol, int32_t *nearRow)
 *
 *   距离度量 = **精确欧氏距离的平方**（不是棋盘/倒角距离）：
 *     - 阶段 1：逐列做 2 遍 1-D 变换，得到每列最近种子的行号 f[row*n+col]
 *               （前向扫描 + 反向扫描，取 min(|v-k|)）
 *     - 阶段 2：逐行做 Felzenszwalb-Huttenlocher 下包络（抛物线求交），
 *               dist = (j - v[k])^2 + g[v[k]]，g[q] = (f-i)^2
 *     无种子时 dist = 1e20f，nearCol/nearRow = -1。
 *   全部用 float 计算（有精度损失），n 为正方形边长。
 * ==========================================================================*/
void edt(const unsigned char *mask, int n, float *dist, int *nearCol, int *nearRow)
{
    int   *f = malloc((size_t)n * n * 4);   /* 每单元格: 最近种子行号, -1 表示无 */
    float *g = malloc((size_t)n * 4);       /* 一行内每列的 (f-i)^2 */
    float *z = malloc((size_t)n * 4 + 4);   /* 抛物线分段边界, 需要 n+1 项 */
    int   *v = malloc((size_t)n * 4);       /* 抛物线顶点(列号) */

    /* ---------- 阶段 1：按列做 1-D 精确距离（只记录行号） ---------- */
    for (int col = 0; col < n; col++) {
        int k = -1;
        for (int row = 0; row < n; row++) {
            if (mask[(size_t)row * n + col]) k = row;
            f[(size_t)row * n + col] = k;                 /* 上方(含自身)最近种子 */
        }
        k = -1;
        for (int row = n - 1; row >= 0; row--) {
            if (mask[(size_t)row * n + col]) k = row;     /* 下方最近种子 */
            int up = f[(size_t)row * n + col];
            if (k >= 0 && (up < 0 || (k - row) < (row - up)))
                f[(size_t)row * n + col] = k;
        }
    }

    /* ---------- 阶段 2：按行做下包络 ---------- */
    for (int row = 0; row < n; row++) {
        int *fr = f + (size_t)row * n;
        for (int q = 0; q < n; q++)
            g[q] = (fr[q] < 0) ? INF_F : (float)((fr[q] - row) * (fr[q] - row));

        int k = 0;
        v[0] = 0;
        z[0] = -INF_F;            /* 0x10d20: (-1e20, +1e20) 一对 float */
        z[1] =  INF_F;

        for (int q = 1; q < n; q++) {
            if (g[q] >= INF_F) continue;                 /* 该列无种子 */
            if (g[v[0]] >= INF_F) { v[0] = q; continue; }/* 首条抛物线无效则替换 */
            /* s = ((g[q]+q^2) - (g[v[k]]+v[k]^2)) / (2q - 2v[k]) */
            float s = ((g[q] + (float)q * q)
                     - (g[v[k]] + (float)v[k] * v[k]))
                     / (2.0f * q - 2.0f * v[k]);
            while (k > 0 && s <= z[k]) {
                k--;
                s = ((g[q] + (float)q * q) - (g[v[k]] + (float)v[k] * v[k]))
                  / (2.0f * q - 2.0f * v[k]);
            }
            k++;
            v[k] = q;
            z[k] = s;
            z[k + 2] = INF_F;        /* 汇编写入 z[k+3]（基址 z+8 字节），偏一格 */
        }

        if (g[v[0]] >= INF_F) {
            /* 整行无种子 */
            for (int j = 0; j < n; j++) {
                dist[(size_t)row * n + j]    = INF_F;
                nearCol[(size_t)row * n + j] = -1;
                nearRow[(size_t)row * n + j] = -1;
            }
            continue;
        }
        k = 0;
        for (int j = 0; j < n; j++) {
            while (z[k + 1] < (float)j) k++;
            size_t i = (size_t)row * n + j;
            float dj = (float)j - (float)v[k];
            dist[i]    = dj * dj + g[v[k]];     /* 平方欧氏距离 */
            nearCol[i] = v[k];                  /* 最近种子的列 */
            nearRow[i] = fr[v[k]];              /* 最近种子的行 */
        }
    }
    free(f); free(g); free(z); free(v);
}


// @addr 0xd9f4 IGDrawOutline

/* ==========================================================================
 * @addr 0xd9f4  IGDrawOutline   (0xd9f4..0xddbc)
 *
 *   void IGDrawOutline(IGCtx *ctx, const float *alpha, const float *mask,
 *                      float unused_s0, float style_s1)
 *
 *   style 只取两端：<=0.2 画"白描边"，>=0.99 画"黑描边"，中间值直接 return。
 *   描边 = 用 2 次 EDT 得到的**有符号距离场**再做 |d| 阈值化（1px 抗锯齿），
 *   半宽 w = (n/1024)*2.6667*0.5 = n/768（@1024 时 1.333，实际线宽 2w≈2.67px）。
 *   颜色 = (color,color,color)，最大混合系数 = 0.15(白) / 0.12(黑)。
 * ==========================================================================*/
void IGDrawOutline(IGCtx *ctx, const float *alpha, const float *mask,
                   float unused_s0, float style)
{
    int  n = ctx->size;

    /* ---- style 门限 ---- */
    float color, gain;
    if (style > 0.2f && style < 0.99f) return;      /* 0x3e4ccccd / 0x3f7d70a4 */
    if (style <= 0.2f) { color = 1.0f; gain = 0.15f; }   /* 白边 */
    else               { color = 0.0f; gain = 0.12f; }   /* 黑边 */

    const int  S = n + 8;                            /* 扩边 4 */
    /* 两张 mask: outside(x23, 默认1) / inside(x24, 默认0) */
    unsigned char *mOut = calloc((size_t)S * S, 1);
    unsigned char *mIn  = calloc((size_t)S * S, 1);
    for (int y = 0; y < S; y++) {
        for (int x = 0; x < S; x++) {
            int in = 0;
            if (y >= 4 && x >= 4 && x < n + 4 && y < n + 4)
                in = (alpha[(y - 4) * n + (x - 4)] >= 0.5f);
            mIn [y * S + x] = (unsigned char)in;      /* 汇编里是 1 起手，随后整段覆盖 */
            mOut[y * S + x] = (unsigned char)(in ^ 1);
        }
    }

    float *dOut = malloc((size_t)S * S * 4);
    float *dIn  = malloc((size_t)S * S * 4);
    int   *idx  = malloc((size_t)S * S * 4);         /* 两次调用共用 */
    int   *lab  = malloc((size_t)S * S * 4);         /* 两次调用共用 */
    edt(mOut, S, dOut, idx, lab);
    edt(mIn,  S, dIn,  idx, lab);

    /* 线宽（"半径"语义，见下） */
    const float w = (float)n / 1024.0f * 2.6666667f * 0.5f;    /* = n/768 */

    for (int y = 0; y < n; y++) {
        for (int x = 0; x < n; x++) {
            int   i   = (y + 4) * S + (x + 4);
            float sdf;
            if (mIn[i]) sdf = -(sqrtf(dOut[i]) - 0.5f);   /* 内: 负(到最近的外点) */
            else        sdf =  (sqrtf(dIn[i])  - 0.5f);   /* 外: 正(到最近的内点) */

            /* 覆盖度：|sdf + (0.5 - alpha)| 与 w 比较，±0.5 做 1px 抗锯齿 */
            float c = fabsf(sdf + (0.5f - alpha[y * n + x]));
            c = (w - c) + 0.5f;
            c = CLAMP01(c);

            /* 额外的逐像素权重（若 mask 非空则 1-mask，否则沿用 0.5-alpha） */
            float k = (mask ? 1.0f - mask[y * n + x] : 0.5f - alpha[y * n + x]);
            float a = c * k;
            if (a <= 0.0f) continue;

            a *= gain;                                   /* 0.15 / 0.12 */
            float *p = ctx->rgb + 3 * ((size_t)y * n + x);
            float ia = 1.0f - a;
            for (int ch = 0; ch < 3; ch++)
                p[ch] = p[ch] * ia + color * a;          /* color = 0 或 1 */
        }
    }
    free(mOut); free(mIn); free(dOut); free(dIn); free(idx); free(lab);
}


// @addr 0xddbc IGCreateIconShape

/* ==========================================================================
 * @addr 0xddbc  IGCreateIconShape   (0xddbc..0xe320)
 *
 *   float *IGCreateIconShape(int n)      // x0 = n，返回 n*n 的 float 覆盖率
 *
 * 用 CoreGraphics 在 n x n 的 8bit 灰度 CGBitmapContext 里填充一条 "圆角方形"
 * 路径，然后把像素 /255 输出成 float 平面（并做上下翻转：CG 是 y 向上）。
 *
 * 形状（设计空间 1024 x 1024，最后按 s = n/1024 缩放）：
 *   - 每条边有 1024-2r = 319.6 (31.2%) 的直线段，剩下两端各 r = 352.2044 (34.4%)
 *     的"角区"，角区用一个 3 段三次贝塞尔曲线连接相邻两条边（端点切线分别
 *     沿两边，所以与直边 G1 连续）。
 *   - 这条角曲线不是圆弧：它是一条超椭圆式曲线，用 |1-u/r|^k + |1-v/r|^k = 1
 *     （u,v 为到角点两条边的距离）拟合得 k ≈ 3.3~3.6；即 45° 方向离角点只有
 *     0.1907r ≈ 67.2/1024 = 6.6% 边长（圆弧应为 0.293r），离角区中心最远达
 *     1.1445r —— 比圆"方"，是 Apple 那种"连续曲率"的方角。
 *     视觉上圆角看起来只有约 10% 边长，而不是 34%。
 *   - 4 个角由同一基准路径经 CGAffineTransformRotate(i*90°) 复制，
 *     角与角之间用 CGPathAddLineToPoint 沿边连接（i==0 用 CGPathMoveToPoint），
 *     最后 CGPathCloseSubpath 补上底边最后一段。
 *
 * 基准角（右下角，从底边 x=671.7956 走向右边 y=352.2044）：
 *   M (671.7956,   0)          <- 与底边相切（切线水平）
 *   C (773.2112,   0) (823.9191,   0) (878.5038,  17.2596)
 *   C (938.1014,  38.9513) (985.0487,  85.8986) (1006.7404, 145.4962)
 *   C (1024,     200.0810) (1024,     250.7888) (1024,     352.2044)   <- 与右边相切
 * 注意这些常量两两互补：1024-671.7956=352.2044, 1024-773.2112=250.7888,
 *   1024-823.9191=200.0810, 1024-878.5038=145.4962, 1024-938.1014=85.8986,
 *   1024-985.0487=38.9513, 1024-1006.7404=17.2596 —— 角曲线关于 45° 线对称。
 * ==========================================================================*/
float *IGCreateIconShape(int n)
{
    CGColorSpaceRef cs  = CGColorSpaceCreateDeviceGray();
    CGContextRef    ctx = CGBitmapContextCreate(NULL, n, n, 8, n, cs, 0);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;

    const double s   = (double)n / 1024.0;       /* scvtf d8, w19, #10 */
    const double cen = 512.0 * s;                /* 0x4080000000000000 = 512 */

    CGMutablePathRef path = CGPathCreateMutable();
    CGAffineTransform t   = CGAffineTransformIdentity;   /* _CGAffineTransformIdentity */

    /* ---- 设计空间常量（与 0x10d28..0x10d98 的 16 个 double 一一对应） ----
     * 注意：汇编里每个点都按 (v, 0) 经仿射变换（cp1/cp2 的 y 项恒为 0，
     * 因为设计路径贴在设计框的底边 / 右边上），所以这里统一用 CGPointMake(x, y)。*/
    const double P0 = 671.795593262;
    /* 三段三次贝塞尔的 cp1 / cp2 / 终点（设计空间 1024 方框，右下角） */
    const double cp1[3][2] = { { 773.211242676,   0.0          },
                               { 938.101379395,  38.9513206482},
                               {1024.0,         200.080963135} };
    const double cp2[3][2] = { { 823.919067383,   0.0          },
                               { 985.048706055,  85.8986129761},
                               {1024.0,         250.788772583} };
    const double endp[3][2]= { { 878.503845215,  17.2595844269},
                               {1006.74041748, 145.496170044 },
                               {1024.0,        352.204406738} };

    for (int i = 0; i < 4; i++) {                 /* w23 = 4 */
        /* t = Translate(+cen) . Rotate(i*pi/2) . Translate(-cen) . Scale(s)
         *   -> p_pixel = R_i(s*(p_design - 512)) + n/2                     */
        CGAffineTransform m = CGAffineTransformIdentity;
        m = CGAffineTransformTranslate(m, cen, cen);
        m = CGAffineTransformRotate(m, (double)i * 1.57079632679);   /* M_PI_2 */
        m = CGAffineTransformTranslate(m, -cen, -cen);
        m = CGAffineTransformScale(m, s, s);

        CGPoint p0 = CGPointApplyAffineTransform(CGPointMake(P0, 0.0), m);
        if (i == 0) CGPathMoveToPoint(path, NULL, p0.x, p0.y);
        else        CGPathAddLineToPoint(path, NULL, p0.x, p0.y);   /* 沿边补齐 */

        for (int k = 0; k < 3; k++) {
            CGPoint a = CGPointApplyAffineTransform(CGPointMake(cp1[k][0], cp1[k][1]), m);
            CGPoint b = CGPointApplyAffineTransform(CGPointMake(cp2[k][0], cp2[k][1]), m);
            CGPoint c = CGPointApplyAffineTransform(CGPointMake(endp[k][0], endp[k][1]), m);
            CGPathAddCurveToPoint(path, NULL, a.x, a.y, b.x, b.y, c.x, c.y);
        }
    }
    CGPathCloseSubpath(path);

    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextAddPath(ctx, path);
    CGContextFillPath(ctx);
    CGPathRelease(path);

    /* 取灰度数据（CG 原点在左下 -> 行序需要翻转），/255 归一化 */
    const unsigned char *data = CGBitmapContextGetData(ctx);
    float *out = malloc((size_t)n * n * 4);
    for (int y = 0; y < n; y++)
        for (int x = 0; x < n; x++)
            out[y * n + x] = (float)data[(size_t)(n - 1 - y) * n + x] / 255.0f;

    CGContextRelease(ctx);
    return out;
}


// @addr 0xe320 boxPass

/* ==========================================================================
 * @addr 0xe320  boxPass   (0xe320..0xe4d4)   盒式模糊单趟（可分离）
 *
 *   void boxPass(float *plane, float *row, int n, int r, int dir)
 *     plane : n x n 的 float 平面，**就地**写回
 *     row   : 长度为 n 的临时行缓冲
 *     r     : 半径（窗口 2r+1）；r < 1 或 n < 1 直接返回
 *     dir   : 1 = 水平（沿行），0 = 垂直（沿列）
 *
 * 算法：滑窗求和 * (1/(2r+1))，边界越界样本按 0 计（不是 clamp），
 *       即边缘向外"补零"——所以贴边的像素会变暗。
 *       下标约定：外循环 i，内循环 j，访问 plane[i*n + j]（dir=1）
 *       或 plane[j*n + i]（dir=0），两者共用 i*n+j 的输出槽位。
 * ==========================================================================*/
void boxPass(float *plane, float *row, int n, int r, int dir)
{
    if (r < 1 || n < 1) return;

    const int    k    = 2 * r + 1;
    const double inv  = 1.0 / (double)k;     /* 只是把 1/(2r+1) 存成 double */

    for (int i = 0; i < n; i++) {
        double sum = 0.0;
        /* 初始窗口：t = 0..2r -> 相对偏移 (t - r)，越界补 0 */
        for (int t = 0; t < k; t++) {
            int j = t - r;
            if (j >= n) break;                        /* b.ls: j >= n 则贡献 0 */
            sum += dir ? plane[i * n + j] : plane[j * n + i];
        }
        for (int j = 0; j < n; j++) {
            row[j] = (float)(sum * inv);
            if (j - r >= 0)                                /* cmn x17,x21 的守卫 */
                sum -= dir ? plane[i * n + (j - r)] : plane[(j - r) * n + i];
            if (j + r + 1 < n)
                sum += dir ? plane[i * n + (j + r + 1)] : plane[(j + r + 1) * n + i];
        }
        /* 写回：dir=1 -> plane[i*n+j]；dir=0 -> plane[j*n+i]（同一线性槽位） */
        for (int j = 0; j < n; j++) {
            if (dir) plane[i * n + j] = row[j];
            else     plane[j * n + i] = row[j];
        }
    }
}
