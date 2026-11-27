//
//  FGCreate.m
//  NGCreateFlatIcon —— 只用分层资源的 layers 重画图标（Mode 0 / Mode 3 走这里）
//
//  地址对照：0x60e4 NGCreateFlatIcon
//

#import "FGInternal.h"

CGImageRef NGCreateFlatIcon(id catalog, NSString *name, uint32_t appearance, size_t px) {
    if (!catalog || !name || px == 0) return NULL;

    NGCatalogIndex *index = FGIndexFor(catalog);
    id stack = FGFindStack(index, name, appearance);
    uint32_t app = appearance;
    if (appearance == 2 && !stack) {          // tintable 没有对应 stack 时退回默认外观
        stack = FGFindStack(index, name, 0);
        app = 0;
    }
    if (!stack) return NULL;

    NGRendition *stackRendition = stack;
    const BOOL tintable = (appearance == 2);

    NSString *appName = (app == 2) ? @"ISAppearanceTintable"
                      : (app == 1) ? @"UIAppearanceDark"
                                   : @"UIAppearanceLight";
    NSNumber *appNum = index.appearances[appName];
    uint16_t theme = (uint16_t)[appNum unsignedShortValue];

    double w = stackRendition.width  ? stackRendition.width  : FG_DEFAULT_SIDE;
    double h = stackRendition.height ? stackRendition.height : FG_DEFAULT_SIDE;

    FGDrawContext ctx = {0};
    ctx.pixelWidth  = px;
    ctx.pixelHeight = px;
    ctx.origin = CGPointZero;
    ctx.size   = CGSizeMake(w, h);
    ctx.foregroundOnly = tintable;

    CGAffineTransform t = CGAffineTransformMakeTranslation(0, (CGFloat)px);
    ctx.ctm = CGAffineTransformScale(t, (CGFloat)((double)px / w), (CGFloat)(-(double)px / h));

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs,
                                           kCGBitmapByteOrder32Little |
                                           kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);
    if (!c) return NULL;

    CGContextSetInterpolationQuality(c, kCGInterpolationHigh);
    CGContextConcatCTM(c, ctx.ctm);

    if (tintable) {
        CGContextSetGrayFillColor(c, 0, 1);
        CGContextFillRect(c, CGRectMake(0, 0, w, h));
    }

    BOOL ok = FGDrawNode(c, &ctx, catalog, index, stackRendition, theme);

    if (tintable && ok) {
        // Rec.709 亮度化：把彩色图标压成灰度覆盖率，供系统着色
        uint8_t *base = CGBitmapContextGetData(c);
        size_t stride = CGBitmapContextGetBytesPerRow(c);
        size_t W = CGBitmapContextGetWidth(c), H = CGBitmapContextGetHeight(c);
        for (size_t y = 0; y < H; y++) {
            uint8_t *row = base + y * stride;
            for (size_t x = 0; x < W; x++) {
                uint8_t *p = row + x * 4;              // BGRA
                double luma = (double)p[0] * 0.0722
                            + (double)p[1] * 0.7152
                            + (double)p[2] * 0.2126 + 0.5;
                if (luma > 255.0) luma = 255.0;
                int v = (int)luma;
                if (p[3] < v) v = p[3];
                p[0] = p[1] = p[2] = (uint8_t)v;
            }
        }
    }

    CGImageRef out = ok ? CGBitmapContextCreateImage(c) : NULL;
    CGContextRelease(c);
    return out;
}
