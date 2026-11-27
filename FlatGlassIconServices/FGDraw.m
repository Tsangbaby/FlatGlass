//
//  FGDraw.m
//  drawNode / drawFill / drawElement
//
//  地址对照：0x64cc drawNode / 0x81e4 drawFill / 0x8c60 drawElement
//

#import "FGInternal.h"

#pragma mark - 单色渐变的亮度派生
//
// 原 0x889c..0x8914 的向量化实现，等价形式：
//     base = c + (-0.2) * (lum - c)
//     k >= 0 : base * (1 + k)
//     k <  0 : base + (1 - base) * k
static double FGAdjustComponent(double c, double lum, double k) {
    double base = c + (-0.2) * (lum - c);
    return (k < 0.0) ? (base + (1.0 - base) * k) : (base * (1.0 + k));
}

#pragma mark - drawFill

BOOL FGDrawFill(CGContextRef c, NGCatalogIndex *index, NSString *fillName,
                uint16_t theme, int forceVertical, CGRect frame)
{
    NGRendition *node = FGByName(index, fillName, theme);
    if (!node) {
        if (FGLog) FGLog([NSString stringWithFormat:@"fill %@ not found", fillName]);
        return NO;
    }

    // ── 纯色 ────────────────────────────────────────────────────────────
    if (node.layout != FG_LAYOUT_FILL) {
        CGColorRef color = FGCreateColor(node);
        if (color) {
            CGContextSetFillColorWithColor(c, color);
            CGContextFillRect(c, frame);
            CGColorRelease(color);
            return YES;
        }
        if (FGLog) {
            FGLog([NSString stringWithFormat:@"fill %@ unreadable (layout 0x%x)",
                   fillName, (unsigned)node.layout]);
        }
        return NO;
    }

    // ── 渐变 ────────────────────────────────────────────────────────────
    uint32_t paySize = 0;
    NSData *csi = node.csi;
    if (csi.length < 0xB8) return NO;
    const uint8_t *base = csi.bytes;
    uint32_t recSize = *(const uint32_t *)(base + 0xA8);
    uint32_t payLen  = *(const uint32_t *)(base + 0xB4);
    if ((size_t)0xB8 + recSize + payLen > csi.length || payLen < 0x0C) return NO;

    const uint8_t *sub = base + 0xB8 + recSize;
    uint32_t magic = *(const uint32_t *)sub;
    uint32_t hdr;
    NGGradient *grad = [NGGradient new];
    uint32_t stopCount = *(const uint32_t *)(sub + 0x04);
    grad.type  = *(const uint32_t *)(sub + 0x08);
    grad.start = CGPointZero;
    grad.end   = CGPointZero;

    if (magic == 0x47475241 /* 'ARGG' */) {
        if (payLen < 0x20) return NO;
        grad.start = CGPointMake(*(const float *)(sub + 0x10), *(const float *)(sub + 0x14));
        grad.end   = CGPointMake(*(const float *)(sub + 0x18), *(const float *)(sub + 0x1C));
        hdr = 0x20;
    } else if (magic == 0x41475241 /* 'ARGA' */) {
        hdr = 0x14;
    } else if (magic == 0x4E475241 /* 'ARGN' */) {
        hdr = 0x10;
    } else {
        return NO;
    }

    NSMutableArray *colors = [NSMutableArray array];
    NSMutableArray *stops  = [NSMutableArray array];
    if (stopCount) {
        const uint8_t *end = sub + payLen;
        const uint8_t *entry = sub + hdr;
        for (uint32_t n = 1; ; n++) {
            if (entry + 8 > end) break;
            float pos = *(const float *)entry;
            uint32_t nameLen = *(const uint32_t *)(entry + 4);
            const uint8_t *namePtr = entry + 8;
            if (namePtr + nameLen > end) break;

            NSString *colorName = [[NSString alloc] initWithBytes:namePtr
                                                           length:strnlen((const char *)namePtr, nameLen)
                                                         encoding:NSUTF8StringEncoding];
            NGRendition *sub0 = colorName ? FGByName(index, colorName, theme) : nil;
            CGColorRef col = sub0 ? FGCreateColor(sub0) : NULL;
            if (!col) {
                if (FGLog) {
                    FGLog([NSString stringWithFormat:@"gradient %@: no color %@",
                           node.name, colorName]);
                }
                return NO;
            }
            [colors addObject:(__bridge id)col];
            CGColorRelease(col);
            [stops addObject:@(pos)];

            if (n >= stopCount) break;
            entry = namePtr + nameLen;
        }
    }
    if (colors.count == 0) return NO;

    grad.colors = colors;
    grad.stops  = stops;

    // ── 组装 CG 渐变用的色标 ────────────────────────────────────────────
    NSMutableArray *cgColors = [NSMutableArray array];
    double stopPos[16] = {0};

    if (grad.type != 0 && grad.colors.count != 1) {
        for (NSUInteger i = 0; i < grad.colors.count && i < 16; i++) {
            [cgColors addObject:grad.colors[i]];
            stopPos[i] = [grad.stops[i] doubleValue];
        }
    } else {
        CGColorRef baseColor = (__bridge CGColorRef)grad.colors[0];
        CGColorRef matched = CGColorCreateCopyByMatchingToColorSpace(
            FGSharedExtendedSRGB(), kCGRenderingIntentDefault, baseColor, NULL);
        CGColorRef src = matched ?: baseColor;

        const CGFloat *comp = CGColorGetComponents(src);
        size_t ncomp = CGColorGetNumberOfComponents(src);

        double r = comp[0], g = r, b = r, a = 1.0;
        if (ncomp >= 4) { g = comp[1]; b = comp[2]; a = comp[3]; }
        else if (ncomp >= 2) { a = comp[1]; }
        if (matched) CGColorRelease(matched);

        double lum = 0.7152 * g + 0.2126 * r + 0.0722 * b;

        double stopA, stopB, k;
        if (lum <= 0.25)      { stopA = 0.0; stopB = 0.7; k =  0.20; }
        else if (lum <= 0.5)  { stopA = 0.0; stopB = 0.7; k =  0.25; }
        else if (lum <= 0.75) { stopA = 0.0; stopB = 0.7; k =  0.30; }
        else                  { stopA = 1.0; stopB = 0.3; k = -0.10; }

        double adj[4] = {
            FGAdjustComponent(r, lum, k),
            FGAdjustComponent(g, lum, k),
            FGAdjustComponent(b, lum, k),
            a,
        };
        CGColorRef adjusted = CGColorCreate(FGSharedExtendedSRGB(), adj);

        CGColorRef first  = (stopA < stopB) ? adjusted : CGColorRetain(baseColor);
        CGColorRef second = (stopA < stopB) ? CGColorRetain(baseColor) : adjusted;
        [cgColors addObject:(__bridge id)first];
        CGColorRelease(first);
        [cgColors addObject:(__bridge id)second];
        CGColorRelease(second);
        stopPos[0] = (stopA < stopB) ? stopA : stopB;
        stopPos[1] = (stopA < stopB) ? stopB : stopA;
    }

    // ── 几何 ────────────────────────────────────────────────────────────
    CGPoint p0 = grad.start, p1 = grad.end;
    if (p0.x == p1.x && p0.y == p1.y) { p0 = CGPointMake(0, 0); p1 = CGPointMake(0, 1); }
    if (forceVertical) {
        if (p0.y > p1.y) { p0.y = 0.9; p1.y = 0.1; }
        else             { p0.y = 0.1; p1.y = 0.9; }
        p0.x = 0.0; p1.x = 0.0;
    }

    CGGradientRef g = CGGradientCreateWithColors(FGSharedExtendedSRGB(),
                                                 (__bridge CFArrayRef)cgColors, stopPos);
    if (!g) return NO;

    CGPoint s = CGPointMake(CGRectGetMinX(frame) + p0.x * frame.size.width,
                            CGRectGetMinY(frame) + p0.y * frame.size.height);
    CGPoint e = CGPointMake(CGRectGetMinX(frame) + p1.x * frame.size.width,
                            CGRectGetMinY(frame) + p1.y * frame.size.height);

    CGContextDrawLinearGradient(c, g, s, e,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    return YES;
}

#pragma mark - drawNode

BOOL FGDrawNode(CGContextRef c, FGDrawContext *ctx, id catalog,
                NGCatalogIndex *index, NGRendition *node, uint16_t theme)
{
    BOOL ok = YES;

    for (NGLayerRef *ref in FGLayerRefs(node.csi)) {
        NGRendition *target = FGResolve(catalog, ref.keyList, theme);
        if (!target) {
            if (FGLog) {
                FGLog([NSString stringWithFormat:@"%@: unresolved ref %@",
                       node.name, FGKeyListDesc(ref.keyList)]);
            }
            ok = NO;
            continue;
        }

        CGRect frame = (ref.frame.size.width > 0 && ref.frame.size.height > 0)
                     ? ref.frame
                     : CGRectMake(ctx->origin.x, ctx->origin.y, ctx->size.width, ctx->size.height);

        if (target.layout == FG_LAYOUT_FILL || target.layout == FG_LAYOUT_FILL_ALT) {
            if (ctx->foregroundOnly) continue;
            CGContextSaveGState(c);
            CGContextSetAlpha(c, (double)ref.opacity);
            if (!FGDrawFill(c, index, target.name, theme, 1, frame)) ok = NO;
            CGContextRestoreGState(c);
        } else if (target.layout == FG_LAYOUT_GROUP) {
            CGContextSaveGState(c);
            CGContextSetAlpha(c, (double)ref.opacity);
            CGContextSetBlendMode(c, (CGBlendMode)ref.blendMode);
            CGContextBeginTransparencyLayer(c, NULL);
            if (!FGDrawNode(c, ctx, catalog, index, target, theme)) ok = NO;
            CGContextEndTransparencyLayer(c);
            CGContextRestoreGState(c);
        } else {
            if (!FGDrawElement(c, ctx, catalog, index, target, ref, theme, frame)) ok = NO;
        }
    }
    return ok;
}

#pragma mark - drawElement

BOOL FGDrawElement(CGContextRef c, FGDrawContext *ctx, id catalog,
                   NGCatalogIndex *index, NGRendition *target,
                   NGLayerRef *ref, uint16_t theme, CGRect frame)
{
    BOOL ok = NO;
    const size_t w = ctx->pixelWidth;
    const size_t h = ctx->pixelHeight;

    CGContextSaveGState(c);
    CGContextSetAlpha(c, (double)ref.opacity);
    CGContextSetBlendMode(c, (CGBlendMode)ref.blendMode);

    NSString *fillName = ref.fill;

    if (!fillName.length) {
        // ── (B) 无 fill ─────────────────────────────────────────────────
        if (target.layout == FG_LAYOUT_IMAGE || target.layout == FG_LAYOUT_IMAGE_ALT) {
            CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGColorSpaceRef p3   = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
            CGContextRef bmp = CGBitmapContextCreate(NULL, w, h, 8, 0, srgb,
                                                     kCGBitmapByteOrder32Little |
                                                     kCGImageAlphaPremultipliedFirst);
            if (bmp) {
                CGContextConcatCTM(bmp, ctx->ctm);
                if (FGDrawContents(bmp, catalog, target, frame)) {
                    CGImageRef img = CGBitmapContextCreateImage(bmp);
                    if (img) {
                        CGImageRef img2 = CGImageCreateCopyWithColorSpace(img, p3);
                        if (img2) {
                            CGContextSaveGState(c);
                            CGAffineTransform inv = CGAffineTransformInvert(ctx->ctm);
                            CGContextConcatCTM(c, inv);
                            CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img2);
                            CGContextRestoreGState(c);
                            ok = YES;
                            CGImageRelease(img2);
                        }
                        CGImageRelease(img);
                    }
                }
                CGContextRelease(bmp);
            }
            if (srgb) CGColorSpaceRelease(srgb);
            if (p3)   CGColorSpaceRelease(p3);
        } else {
            ok = FGDrawContents(c, catalog, target, frame);
        }
        goto finish;
    }

    // ── (A) 有 fill：先渲染 alpha 掩膜，再按掩膜裁剪填充 ────────────────
    {
        CGContextRef bmp = CGBitmapContextCreate(NULL, w, h, 8, w, NULL, kCGImageAlphaOnly);
        if (!bmp) goto finish;

        CGContextSetInterpolationQuality(bmp, kCGInterpolationHigh);
        CGContextConcatCTM(bmp, ctx->ctm);

        if (!FGDrawContents(bmp, catalog, target, frame)) {
            CGContextRelease(bmp);
            goto finish;
        }

        const uint8_t *data = CGBitmapContextGetData(bmp);
        size_t bpr = CGBitmapContextGetBytesPerRow(bmp);
        int64_t minX = (int64_t)w, maxX = -1, minY = (int64_t)h, maxY = -1;
        for (int64_t row = 0; row < (int64_t)h; row++) {
            const uint8_t *line = data + row * bpr;
            for (int64_t col = 0; col < (int64_t)w; col++) {
                if (line[col] < 9) continue;
                if (col < minX) minX = col;
                if (col > maxX) maxX = col;
                if (row < minY) minY = row;
                if (row > maxY) maxY = row;
            }
        }

        CGAffineTransform inv = CGAffineTransformInvert(ctx->ctm);

        if (maxX >= 0) {
            CGRect box = CGRectMake((double)minX,
                                    (double)((int64_t)h - 1 - maxY),
                                    (double)(maxX - minX + 1),
                                    (double)(maxY - minY + 1));
            frame = CGRectStandardize(CGRectApplyAffineTransform(box, &inv));
        }

        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CFDataRef d = CFDataCreate(NULL, data, (CFIndex)(h * bpr));
        CGDataProviderRef prov = CGDataProviderCreateWithCFData(d);
        CGImageRef mask = CGImageCreate(w, h, 8, 8, bpr, gray, 0, prov, NULL, false, 0);
        CGDataProviderRelease(prov);
        CFRelease(d);
        CGColorSpaceRelease(gray);
        CGContextRelease(bmp);

        if (!mask) goto finish;

        CGContextBeginTransparencyLayer(c, NULL);
        CGContextConcatCTM(c, inv);
        CGContextClipToMask(c, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), mask);
        CGContextConcatCTM(c, ctx->ctm);

        ok = FGDrawFill(c, index, fillName, theme, 0, frame);

        CGContextEndTransparencyLayer(c);
        CGImageRelease(mask);
    }

finish:
    CGContextRestoreGState(c);
    if (!ok && FGLog) {
        FGLog([NSString stringWithFormat:@"element %@ (layout 0x%x) failed",
               target.name, (unsigned)target.layout]);
    }
    return ok;
}
