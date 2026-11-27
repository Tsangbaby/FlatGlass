//
//  FGRender.m
//  FlatGlass
//
//  Port of the icon compositor. Sections are ordered by call depth:
//  fill -> element -> node -> entry points.
//

#import "FGRender.h"
#import "FGResolve.h"
#import "FGCatalog.h"
#import "FGCompat.h"
#import "FGWrap.h"
#import "FGCommon.h"
#import "FGLog.h"

#import "FGShape.h"
#import "FGEffects.h"

#import <dlfcn.h>
#import <math.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>

// Byte readers used by the gradient parser. Kept local so this file has no
// link-time dependency on the resolver's internals.
static inline uint32_t FGReadU32Raw(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, sizeof(v)); return v;
}
static inline float FGReadF32Raw(const uint8_t *p) {
    float v; memcpy(&v, p, sizeof(v)); return v;
}

// Rec.709 luminance weights, lifted verbatim from the binary's constants at
// 0x10b58 / 0x10b60 / 0x10b68. Order matters: the pixel loop multiplies B by
// w[0], G by w[1] and R by w[2].
static const double kFGWeightB = 0.7152;
static const double kFGWeightG = 0.0722;
static const double kFGWeightR = 0.2126;

static CGColorSpaceRef FGExtendedSRGB(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    });
    return space;
}

static CGColorSpaceRef FGDeviceRGB(void) {
    static CGColorSpaceRef space;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    });
    return space;
}

#pragma mark - Gradient parsing

// Gradient payload, three header flavours share one tag field:
//
//   ARGN  0x10 byte header, inline colour list
//   ARGA  0x14 byte header
//   ARGG  0x20 byte header, carries explicit start/end points
//
// Every flavour then repeats: { float stop, uint32 nameLen, char name[nameLen] }

static NGGradient *FGParseGradient(NGRendition *fill, NGCatalogIndex *index, uint32_t token) {
    NSData *csi = fill.csi;
    if (!csi || csi.length < 0xb8) return nil;

    const uint8_t *base = (const uint8_t *)csi.bytes;
    uint32_t headerLen  = FGReadU32Raw(base + 0xa8);
    uint32_t payloadLen = FGReadU32Raw(base + 0xb4);

    const uint8_t *p = base + 0xb8 + headerLen;
    const uint8_t *end = p + payloadLen;
    if (end > base + csi.length) end = base + csi.length;
    if (p + 0x10 > end) return nil;

    NGGradient *gradient = [NGGradient new];

    uint32_t tag = FGReadU32Raw(p);
    uint32_t type = FGReadU32Raw(p + 8);
    uint32_t count = FGReadU32Raw(p + 4);
    gradient.type = type;

    // Defaults come from a constant pair in __TEXT; a zero-to-one vertical
    // ramp is what they resolve to.
    gradient.start = CGPointMake(0, 0);
    gradient.end   = CGPointMake(0, 1);

    // Tag values read as little-endian uint32 of the ASCII bytes.
    uint32_t headerSize;
    if (tag == 0x47475241 /* "ARGG" */) {
        headerSize = 0x20;
        if (payloadLen >= 0x20) {
            gradient.start = CGPointMake(FGReadF32Raw(p + 0x10), FGReadF32Raw(p + 0x14));
            gradient.end   = CGPointMake(FGReadF32Raw(p + 0x18), FGReadF32Raw(p + 0x1c));
        }
    } else if (tag == 0x41475241 /* "ARGA" */) {
        headerSize = 0x14;
    } else if (tag == 0x4e475241 /* "ARGN" */) {
        headerSize = 0x10;
    } else {
        return nil;
    }

    if (count == 0) return nil;

    NSMutableArray *colors = [NSMutableArray array];
    NSMutableArray<NSNumber *> *stops = [NSMutableArray array];

    const uint8_t *cursor = p + headerSize;
    for (uint32_t i = 0; i < count; i++) {
        if (cursor + 8 > end) break;
        float stop = FGReadF32Raw(cursor);
        uint32_t nameLen = FGReadU32Raw(cursor + 4);
        if (cursor + 8 + nameLen > end) break;

        NSString *colorName = [[NSString alloc] initWithBytes:cursor + 8
                                                       length:strnlen((const char *)cursor + 8, nameLen)
                                                     encoding:NSUTF8StringEncoding];
        NGRendition *colorRecord = colorName ? FGByName(index, colorName, token) : nil;
        CGColorRef color = colorRecord ? FGCreateColor(colorRecord) : NULL;

        if (color) {
            // Box the CGColorRef so NSArray can hold it; released in -dealloc.
            [colors addObject:[NSValue valueWithPointer:color]];
            [stops addObject:@(stop)];
        } else {
            FGLogf(@"gradient %@: no color %@", fill.name, colorName);
        }

        cursor += 8 + nameLen;
    }

    if (colors.count == 0) return nil;
    gradient.colors = colors;
    gradient.stops = stops;
    return gradient;
}

#pragma mark - Fill

// Single-colour gradients get a second stop synthesised from the source
// luminance. The thresholds below are exact: the branches compare against
// 0.25 / 0.5 / 0.75 and pick (k, spread, invert) accordingly.
static CGFloat FGAdjustChannel(CGFloat value, double luminance, double k) {
    double base = value - 0.2 * (luminance - value);
    double up   = base + base * k;
    double down = base + (1.0 - base) * k;
    return (k < 0) ? down : up;
}

static void FGSynthesizeSecondStop(CGColorRef color, CGColorRef *outColor, double *outStop) {
    *outColor = NULL;
    *outStop = 1.0;

    CGColorRef converted = CGColorCreateCopyByMatchingToColorSpace(FGExtendedSRGB(),
                                                                  kCGRenderingIntentDefault,
                                                                  color, NULL);
    CGColorRef source = converted ?: color;
    const CGFloat *comp = CGColorGetComponents(source);
    size_t n = CGColorGetNumberOfComponents(source);
    if (!comp || n == 0) {
        if (converted) CGColorRelease(converted);
        return;
    }

    CGFloat r = comp[0], g = r, b = r, a = 1.0;
    if (n >= 4) {
        g = comp[1]; b = comp[2]; a = comp[3];
    } else if (n >= 2) {
        a = comp[1];
    }

    double luminance = g * kFGWeightB + r * kFGWeightR + b * kFGWeightG;

    double k, spread, invert;
    if (luminance <= 0.25) {
        k = 0.2; spread = 0.7; invert = 0.0;
    } else if (luminance <= 0.5) {
        k = 0.25; spread = 0.7; invert = 0.0;
    } else if (luminance <= 0.75) {
        k = 0.3; spread = 0.7; invert = 0.0;
    } else {
        k = -0.1; spread = 0.3; invert = 1.0;
    }

    CGFloat nr = FGAdjustChannel(r, luminance, k);
    CGFloat ng = FGAdjustChannel(g, luminance, k);
    CGFloat nb = FGAdjustChannel(b, luminance, k);

    // Blue gets one extra contrast pass before the blend below.
    double base = b - 0.2 * (luminance - b);
    double blended = (k < 0) ? (base + k * (1.0 - base)) : (base + k * base);

    CGFloat components[4] = { nr, ng, (CGFloat)blended, a };
    *outColor = CGColorCreate(FGExtendedSRGB(), components);
    *outStop  = spread;

    if (converted) CGColorRelease(converted);
    (void)invert;
}

BOOL FGDrawFill(CGContextRef ctx, NGCatalogIndex *index, NSString *name,
                uint32_t token, BOOL normalizeDirection, CGRect rect, id resource) {
    NGRendition *fill = FGByName(index, name, token);
    if (!fill) {
        FGLogf(@"fill %@ not found", name);
        return NO;
    }

    if (fill.layout != FGLayoutGradient) {
        CGColorRef color = FGCreateColor(fill);
        if (!color) {
            FGLogf(@"fill %@ unreadable (layout 0x%x)", name, fill.layout);
            return NO;
        }
        CGContextSetFillColorWithColor(ctx, color);
        CGContextFillRect(ctx, rect);
        CGColorRelease(color);
        return YES;
    }

    NGGradient *gradient = FGParseGradient(fill, index, token);
    if (!gradient) {
        FGLogf(@"fill %@ unreadable (layout 0x%x)", name, fill.layout);
        return NO;
    }

    // Build parallel colour / location arrays, capped at 16 stops.
    NSMutableArray *cgColors = [NSMutableArray array];
    CGFloat locations[16];
    NSUInteger limit = 0;
    CGColorRef synthesized = NULL;

    if (gradient.colors.count == 1) {
        CGColorRef base = (CGColorRef)[(NSValue *)gradient.colors.firstObject pointerValue];
        double stop = 1.0;
        FGSynthesizeSecondStop(base, &synthesized, &stop);
        if (!synthesized) return NO;

        [cgColors addObject:(__bridge id)base];
        [cgColors addObject:(__bridge id)synthesized];
        locations[0] = 0.0;
        locations[1] = (CGFloat)stop;
        limit = 2;
    } else {
        limit = MIN(gradient.colors.count, (NSUInteger)16);
        for (NSUInteger i = 0; i < limit; i++) {
            CGColorRef c = (CGColorRef)[(NSValue *)gradient.colors[i] pointerValue];
            if (!c) continue;
            [cgColors addObject:(__bridge id)c];
            locations[cgColors.count - 1] =
                gradient.stops.count > i ? gradient.stops[i].doubleValue : 0.0;
        }
        limit = cgColors.count;
    }

    if (cgColors.count == 0) {
        if (synthesized) CGColorRelease(synthesized);
        return NO;
    }

    CGGradientRef gradientRef = CGGradientCreateWithColors(FGExtendedSRGB(),
                                                           (__bridge CFArrayRef)cgColors,
                                                           locations);
    if (synthesized) CGColorRelease(synthesized);
    if (!gradientRef) return NO;

    CGPoint start = gradient.start;
    CGPoint end   = gradient.end;

    // A zero-length ramp means "no direction given"; fall back to top-to-bottom.
    if (start.x == end.x && start.y == end.y) {
        start = CGPointMake(0, 0);
        end   = CGPointMake(0, 1);
    }

    if (normalizeDirection && start.y != end.y) {
        // Keep the highlight pointing the same way regardless of how the
        // artwork was authored.
        if (start.y > end.y) {
            CGPoint tmp = start; start = end; end = tmp;
        }
    }

    CGPoint p0 = CGPointMake(CGRectGetMinX(rect) + start.x * rect.size.width,
                             CGRectGetMinY(rect) + start.y * rect.size.height);
    CGPoint p1 = CGPointMake(CGRectGetMinX(rect) + end.x * rect.size.width,
                             CGRectGetMinY(rect) + end.y * rect.size.height);

    CGContextDrawLinearGradient(ctx, gradientRef, p0, p1,
                                kCGGradientDrawsBeforeStartLocation |
                                kCGGradientDrawsAfterEndLocation);

    CGGradientRelease(gradientRef);
    return YES;
}

#pragma mark - Contents

static BOOL FGDrawSVG(CGContextRef ctx, NSData *data, CGRect frame) {
    typedef void *(*CreateFn)(CFDataRef, int);
    typedef void (*ReleaseFn)(void *);
    typedef CGSize (*CanvasSizeFn)(void *);
    typedef void (*DrawFn)(CGContextRef, void *);

    static CreateFn  create;
    static ReleaseFn release;
    static CanvasSizeFn canvasSize;
    static DrawFn    draw;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/CoreSVG.framework/CoreSVG",
                              RTLD_LAZY);
        if (!handle) return;
        create     = (CreateFn)dlsym(handle, "CGSVGDocumentCreateFromData");
        release    = (ReleaseFn)dlsym(handle, "CGSVGDocumentRelease");
        canvasSize = (CanvasSizeFn)dlsym(handle, "CGSVGDocumentGetCanvasSize");
        draw       = (DrawFn)dlsym(handle, "CGContextDrawSVGDocument");
    });

    if (!create || !release || !canvasSize || !draw) return NO;

    void *document = create((__bridge CFDataRef)data, 0);
    if (!document) return NO;

    @try {
        CGSize size = canvasSize(document);
        if (!(isfinite(size.width) && size.width > 0 && isfinite(size.height) && size.height > 0)) {
            return NO;
        }

        CGContextSaveGState(ctx);
        @try {
            CGContextTranslateCTM(ctx, CGRectGetMinX(frame), CGRectGetMaxY(frame));
            CGContextScaleCTM(ctx, frame.size.width / size.width, -frame.size.height / size.height);
            draw(ctx, document);
        } @finally {
            CGContextRestoreGState(ctx);
        }
        return YES;
    } @finally {
        release(document);
    }
}

static CGImageRef FGDecodeBitmap(NSData *data) {
    if (!data.length) return NULL;

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    return image;
}

BOOL FGDrawContents(CGContextRef ctx, id resource, NGRendition *rendition, CGRect frame) {
    uint32_t layout = rendition.layout;
    if (layout != FGLayoutLayered && layout != FGLayoutImage) return NO;

    NSData *payload = FGRawData(rendition);
    if (!payload || payload.length == 0) {
        FGLogf(@"%@ has no payload", rendition.name);
        return NO;
    }

    CGImageRef image = FGDecodeBitmap(payload);
    if (image) {
        CGContextSaveGState(ctx);
        // IconServices stores artwork top-down; CoreGraphics draws bottom-up.
        CGContextTranslateCTM(ctx, CGRectGetMinX(frame), CGRectGetMaxY(frame));
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextDrawImage(ctx, CGRectMake(0, 0, frame.size.width, frame.size.height), image);
        CGContextRestoreGState(ctx);
        CGImageRelease(image);
        return YES;
    }

    // Not a bitmap — try SVG through CoreSVG.
    if (FGDrawSVG(ctx, payload, frame)) return YES;

    FGLogf(@"%@  svg %lu bytes: undecodable", rendition.name, (unsigned long)payload.length);
    return NO;
}

#pragma mark - Node walk

BOOL FGDrawNode(CGContextRef ctx, FGDrawState *state, id resource,
                NGCatalogIndex *index, NGRendition *rendition, uint32_t token) {
    BOOL ok = YES;

    NSArray<NGLayerRef *> *layers = FGParseLayerRefs(rendition.csi);
    for (NGLayerRef *layer in layers) {
        NGRendition *child = FGResolve(index, layer.keyList, token);
        if (!child) {
            FGLogf(@"%@: unresolved ref %@", rendition.name, FGKeyListDescription(layer.keyList));
            ok = NO;
            continue;
        }

        CGRect frame = layer.frame;
        if (frame.size.width <= 0 || frame.size.height <= 0) {
            frame = state->bounds;
        }

        switch (child.layout) {
            case FGLayoutSolidFill:
            case FGLayoutGradient: {
                if (state->tintable) break;
                CGContextSaveGState(ctx);
                CGContextSetAlpha(ctx, layer.opacity);
                FGDrawFill(ctx, index, child.name, token, YES, state->bounds, nil);
                CGContextRestoreGState(ctx);
                break;
            }
            case FGLayoutComposite: {
                CGContextSaveGState(ctx);
                CGContextSetAlpha(ctx, layer.opacity);
                CGContextSetBlendMode(ctx, (CGBlendMode)layer.blendMode);
                CGContextBeginTransparencyLayer(ctx, NULL);
                ok = FGDrawNode(ctx, state, resource, index, child, token) && ok;
                CGContextEndTransparencyLayer(ctx);
                CGContextRestoreGState(ctx);
                break;
            }
            default: {
                ok = FGDrawElement(ctx, state, resource, index, child, layer, token, frame) && ok;
                break;
            }
        }
    }

    return ok;
}

#pragma mark - Element

// Alpha threshold below which a pixel is treated as outside the artwork when
// computing the mask bounding box.
static const uint8_t kFGAlphaThreshold = 9;

BOOL FGDrawElement(CGContextRef ctx, FGDrawState *state, id resource,
                   NGCatalogIndex *index, NGRendition *rendition,
                   NGLayerRef *layer, uint32_t token, CGRect frame) {
    CGContextSaveGState(ctx);
    CGContextSetAlpha(ctx, layer.opacity);
    CGContextSetBlendMode(ctx, (CGBlendMode)layer.blendMode);

    BOOL ok = NO;
    NSString *fillName = layer.fill;

    if (fillName.length > 0) {
        // Render the artwork's alpha into a scratch buffer, take its bounding
        // box, then paint the fill through that mask.
        size_t w = (size_t)state->pixelSize.width;
        size_t h = (size_t)state->pixelSize.height;
        if (w == 0 || h == 0) {
            CGContextRestoreGState(ctx);
            return NO;
        }

        CGContextRef scratch = CGBitmapContextCreate(NULL, w, h, 8, w, NULL,
                                                     kCGImageAlphaOnly);
        if (!scratch) {
            CGContextRestoreGState(ctx);
            return NO;
        }
        CGContextSetInterpolationQuality(scratch, kCGInterpolationMedium);
        CGContextConcatCTM(scratch, state->ctm);

        BOOL drawn = FGDrawContents(scratch, resource, rendition, frame);
        if (!drawn) {
            CGContextRelease(scratch);
            CGContextRestoreGState(ctx);
            return NO;
        }

        uint8_t *bits = CGBitmapContextGetData(scratch);
        size_t bpr = CGBitmapContextGetBytesPerRow(scratch);

        NSInteger minX = (NSInteger)w, minY = (NSInteger)h;
        NSInteger maxX = -1, maxY = -1;

        if (bits) {
            for (size_t y = 0; y < h; y++) {
                const uint8_t *row = bits + y * bpr;
                for (size_t x = 0; x < w; x++) {
                    if (row[x] < kFGAlphaThreshold) continue;
                    if ((NSInteger)x < minX) minX = (NSInteger)x;
                    if ((NSInteger)x > maxX) maxX = (NSInteger)x;
                    if ((NSInteger)y < minY) minY = (NSInteger)y;
                    if ((NSInteger)y > maxY) maxY = (NSInteger)y;
                }
            }
        }

        CGAffineTransform inverse = CGAffineTransformInvert(state->ctm);
        CGRect clipRect = CGRectZero;
        if (maxX >= minX && maxY >= minY) {
            // CoreGraphics rows run bottom-up, hence the flip on the origin.
            clipRect = CGRectMake((CGFloat)minX,
                                  (CGFloat)h - 1.0 - (CGFloat)maxY,
                                  (CGFloat)(maxX - minX + 1),
                                  (CGFloat)(maxY - minY + 1));
            clipRect = CGRectStandardize(CGRectApplyAffineTransform(clipRect, inverse));
        }

        // Build the mask image from the scratch buffer before releasing it.
        CGImageRef mask = NULL;
        if (bits) {
            CFDataRef raw = CFDataCreate(NULL, bits, (CFIndex)(bpr * h));
            if (raw) {
                CGDataProviderRef provider = CGDataProviderCreateWithCFData(raw);
                CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
                if (provider && gray) {
                    mask = CGImageCreate(w, h, 8, 8, bpr, gray, kCGImageAlphaNone,
                                         provider, NULL, false, kCGRenderingIntentDefault);
                }
                if (gray) CGColorSpaceRelease(gray);
                if (provider) CGDataProviderRelease(provider);
                CFRelease(raw);
            }
        }

        CGContextRelease(scratch);

        if (mask) {
            CGContextBeginTransparencyLayer(ctx, NULL);
            CGContextConcatCTM(ctx, inverse);
            CGContextClipToMask(ctx, clipRect, mask);
            CGContextConcatCTM(ctx, state->ctm);
            ok = FGDrawFill(ctx, index, fillName, token, NO, clipRect, resource);
            CGContextEndTransparencyLayer(ctx);
            CGImageRelease(mask);
        }
    } else if (rendition.layout == FGLayoutLayered || rendition.layout == FGLayoutImage) {
        // Colour-managed path: render into sRGB first, then hand the result to
        // the caller's extended-sRGB context.
        size_t w = (size_t)state->pixelSize.width;
        size_t h = (size_t)state->pixelSize.height;

        CGContextRef scratch = CGBitmapContextCreate(NULL, w, h, 8, 0, FGDeviceRGB(),
                                                     0x2002 /* BGRA8888 */);
        if (scratch) {
            CGContextConcatCTM(scratch, state->ctm);
            if (FGDrawContents(scratch, resource, rendition, frame)) {
                CGImageRef raw = CGBitmapContextCreateImage(scratch);
                if (raw) {
                    CGImageRef converted = CGImageCreateCopyWithColorSpace(raw, FGExtendedSRGB());
                    if (converted) {
                        CGContextSaveGState(ctx);
                        CGAffineTransform inverse = CGAffineTransformInvert(state->ctm);
                        CGContextConcatCTM(ctx, inverse);
                        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), converted);
                        CGContextRestoreGState(ctx);
                        CGImageRelease(converted);
                        ok = YES;
                    }
                    CGImageRelease(raw);
                }
            }
            CGContextRelease(scratch);
        }
    } else {
        ok = FGDrawContents(ctx, resource, rendition, frame);
    }

    if (!ok) {
        FGLogf(@"element %@ (layout 0x%x) failed", rendition.name, rendition.layout);
    }

    CGContextRestoreGState(ctx);
    return ok;
}

#pragma mark - Flat entry

CGImageRef NGCreateFlatIcon(NGCatalogIndex *index, NSString *name,
                            uint32_t appearance, uint64_t pixelSize) {
    if (!index || !name || pixelSize == 0) return NULL;

    NGRendition *stack = FGFindStack(index, name, appearance);
    if (!stack && appearance == 2) {
        stack = FGFindStack(index, name, 0);
    }
    if (!stack) return NULL;

    BOOL tintable = (appearance == 2);

    // Pick the appearance token from the catalog's own dictionary.
    NSString *appearanceKey = FGAppearanceKey(appearance);
    NSNumber *tokenNumber = index.appearances[appearanceKey];
    uint32_t token = tokenNumber ? tokenNumber.unsignedShortValue : 0;

    CGFloat w = stack.width  ?: 0x400;
    CGFloat h = stack.height ?: 0x400;

    FGDrawState state;
    memset(&state, 0, sizeof(state));
    state.pixelSize = CGSizeMake((CGFloat)pixelSize, (CGFloat)pixelSize);
    state.ctm = CGAffineTransformIdentity;
    state.bounds = CGRectMake(0, 0, w, h);
    state.tintable = tintable;

    double size = (double)pixelSize;
    state.ctm = CGAffineTransformMakeTranslation(0, size);
    state.ctm = CGAffineTransformScale(state.ctm, size / w, -size / h);

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelSize, pixelSize, 8, 0,
                                             space, 0x2002 /* BGRA8888 */);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextConcatCTM(ctx, state.ctm);

    if (tintable) {
        // Tintable artwork is drawn as a mask over solid black.
        CGContextSetGrayFillColor(ctx, 0.0, 1.0);
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
    }

    if (!FGDrawNode(ctx, &state, nil, index, stack, token)) {
        CGContextRelease(ctx);
        return NULL;
    }

    // Flatten: collapse every pixel to its luminance and clamp the result to
    // the source alpha. This is what removes the gloss — the artwork keeps its
    // shape, the highlight gradients become even mid-tones.
    uint8_t *bits = CGBitmapContextGetData(ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(ctx);
    if (bits) {
        for (size_t y = 0; y < pixelSize; y++) {
            uint8_t *row = bits + y * bpr;
            for (size_t x = 0; x < pixelSize; x++) {
                uint8_t *px = row + x * 4;   // B, G, R, A
                double b = px[0], g = px[1], r = px[2], a = px[3];
                double lum = b * kFGWeightG + g * kFGWeightB + r * kFGWeightR + 0.5;
                if (lum > 255.0) lum = 255.0;
                uint8_t v = (uint8_t)lum;
                if (v > (uint8_t)a) v = (uint8_t)a;
                px[0] = v; px[1] = v; px[2] = v;
            }
        }
    }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

CGImageRef NGCreateGlassIconContent(NGCatalogIndex *index, NSString *name,
                                    uint32_t appearance, uint64_t pixelSize) {
    return NGCreateGlassIcon(index, name, appearance, pixelSize);
}

CGImageRef NGCreateGlassIcon(NGCatalogIndex *index, NSString *name,
                             uint32_t appearance, uint64_t pixelSize) {
    if (!index || !name || pixelSize == 0) return NULL;

    NGRendition *stack = FGFindStack(index, name, appearance);
    if (!stack && appearance == 2) stack = FGFindStack(index, name, 0);
    if (!stack) return NULL;

    NSString *appearanceKey = FGAppearanceKey(appearance);
    NSNumber *tokenNumber = index.appearances[appearanceKey];
    uint32_t token = tokenNumber ? tokenNumber.unsignedShortValue : 0;

    CGFloat w = stack.width  ?: 0x400;
    CGFloat h = stack.height ?: 0x400;

    FGDrawState state;
    memset(&state, 0, sizeof(state));
    state.pixelSize = CGSizeMake((CGFloat)pixelSize, (CGFloat)pixelSize);
    state.bounds = CGRectMake(0, 0, w, h);
    state.tintable = (appearance == 2);

    double size = (double)pixelSize;
    state.ctm = CGAffineTransformMakeTranslation(0, size);
    state.ctm = CGAffineTransformScale(state.ctm, size / w, -size / h);

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(NULL, pixelSize, pixelSize, 8, 0, space, 0x2002);
    CGColorSpaceRelease(space);
    if (!ctx) return NULL;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextConcatCTM(ctx, state.ctm);

    if (!FGDrawNode(ctx, &state, nil, index, stack, token)) {
        CGContextRelease(ctx);
        return NULL;
    }

    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

#pragma mark - Edge / gloss entry points

CGImageRef NGCreateRimmedImage(CGImageRef source) {
    if (!source) return NULL;

    size_t w = CGImageGetWidth(source);
    size_t h = CGImageGetHeight(source);
    if (w == 0 || h == 0) return NULL;

    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, FGDeviceRGB(), 0x2002);
    if (!ctx) return NULL;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), source);

    uint8_t *bits = CGBitmapContextGetData(ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(ctx);

    if (bits) {
        uint8_t *mask = calloc(w * h, 1);
        uint8_t *edge = calloc(w * h, 1);
        if (mask && edge) {
            for (size_t y = 0; y < h; y++) {
                for (size_t x = 0; x < w; x++) {
                    mask[y * w + x] = bits[y * bpr + x * 4 + 3];
                }
            }

            // Distance transform produces the inward falloff used for the rim.
            FGEdgeDistance(mask, edge, (int)w, (int)h);

            for (size_t y = 0; y < h; y++) {
                uint8_t *row = bits + y * bpr;
                for (size_t x = 0; x < w; x++) {
                    uint8_t d = edge[y * w + x];
                    if (d == 0) continue;
                    float t = (float)d / 255.0f;
                    // Soft white rim, composited additively but clamped.
                    float add = 255.0f * t * 0.55f;
                    float r = row[x * 4 + 2] + add;
                    float g = row[x * 4 + 1] + add;
                    float b = row[x * 4 + 0] + add;
                    row[x * 4 + 2] = (uint8_t)fminf(r, 255.0f);
                    row[x * 4 + 1] = (uint8_t)fminf(g, 255.0f);
                    row[x * 4 + 0] = (uint8_t)fminf(b, 255.0f);
                }
            }
        }
        free(mask);
        free(edge);
    }

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

CGImageRef NGCreateGlassedImage(CGImageRef source, uint32_t flags) {
    if (!source) return NULL;

    size_t w = CGImageGetWidth(source);
    size_t h = CGImageGetHeight(source);
    if (w == 0 || h == 0) return NULL;

    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, FGDeviceRGB(), 0x2002);
    if (!ctx) return NULL;

    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), source);

    uint8_t *bits = CGBitmapContextGetData(ctx);
    size_t bpr = CGBitmapContextGetBytesPerRow(ctx);

    if (bits) {
        float *shape = IGCreateIconShape((int)w);
        if (shape) {
            uint8_t *rgba = calloc(w * h * 4, 1);
            if (rgba) {
                for (size_t i = 0; i < w * h; i++) {
                    rgba[i * 4 + 0] = bits[(i / w) * bpr + (i % w) * 4 + 0];
                    rgba[i * 4 + 1] = bits[(i / w) * bpr + (i % w) * 4 + 1];
                    rgba[i * 4 + 2] = bits[(i / w) * bpr + (i % w) * 4 + 2];
                    rgba[i * 4 + 3] = bits[(i / w) * bpr + (i % w) * 4 + 3];
                }

                IGDrawChicletHighlights(rgba, shape, (int)w, (int)h, (int)flags);

                for (size_t i = 0; i < w * h; i++) {
                    bits[(i / w) * bpr + (i % w) * 4 + 0] = rgba[i * 4 + 0];
                    bits[(i / w) * bpr + (i % w) * 4 + 1] = rgba[i * 4 + 1];
                    bits[(i / w) * bpr + (i % w) * 4 + 2] = rgba[i * 4 + 2];
                }
                free(rgba);
            }
            free(shape);
        }
    }

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

#pragma mark - Hook entry points

static NSString *FGImageNameForResource(id resource) {
    @try {
        return [resource valueForKey:@"imageName"];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static uint32_t FGAppearanceForResource(id resource) {
    SEL sel = @selector(catalogAppearance);
    if (![resource respondsToSelector:sel]) return 0;
    @try {
        // KVC boxes the integer getter. Sending it through performSelector:
        // would tell ARC to treat the returned scalar as an ObjC object.
        id boxed = [resource valueForKey:@"catalogAppearance"];
        if ([boxed isKindOfClass:[NSNumber class]]) {
            NSNumber *number = boxed;
            unsigned long long value = number.unsignedLongLongValue;
            // The reference renderer only accepts appearance values 0–2.
            if (value <= 2 && [number isEqualToNumber:@(value)]) return (uint32_t)value;
        }
    } @catch (__unused NSException *e) {
        // An unavailable or incompatible getter must not select custom output.
    }
    return UINT32_MAX;
}

id FGResourceImage(id self, SEL _cmd, CGSize size, double scale) {
    uint64_t state = 0;
    int status = notify_get_state(FGModeToken, &state);

    // Published state is (Mode + 1) for Mode 0..3, so the valid window is
    // 1..4. State 3 is "Off" and must bypass catalog parsing entirely.
    double points = fmax(size.width, size.height);
    if (status != NOTIFY_STATUS_OK || state < 1 || state > 4 || state == 3 ||
        !isfinite(points) || points <= 0 || !isfinite(scale) || scale <= 0) {
        return ((id (*)(id, SEL, CGSize, double))FGOriginalResourceImage)(self, _cmd, size, scale);
    }

    // Preserve the requested point edge when the pixel canvas is clamped.
    uint64_t pixels = (uint64_t)fmin(fmax(ceil(points * scale), 16.0), 1024.0);
    CGFloat imageScale = (CGFloat)pixels / points;
    @try {
        if (isfinite(imageScale) && imageScale > 0) {
            NSString *name = FGImageNameForResource(self);
            uint32_t appearance = FGAppearanceForResource(self);
            if (name.length && appearance <= 2) {
                NGCatalogIndex *index = FGIndexForResource(self);
                if (FGFindStack(index, name, appearance)) {
                    CGImageRef rendered = (state == 2)
                        ? NGCreateGlassIconContent(index, name, appearance, pixels)
                        : NGCreateFlatIcon(index, name, appearance, pixels);
                    if (rendered) {
                        @try {
                            id image = FGWrapImage(rendered, imageScale);
                            if (image) return image;
                        } @finally {
                            CGImageRelease(rendered);
                        }
                    }
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[FlatGlass] resource render failed: %@", e.reason);
    }

    return ((id (*)(id, SEL, CGSize, double))FGOriginalResourceImage)(self, _cmd, size, scale);
}

// The saved compositor returns an IFImage-like object. These two selectors
// return a Core Graphics reference and a floating-point scalar, not id.
@protocol FGComposedImageResult <NSObject>
@property (nonatomic, readonly) CGImageRef CGImage;
@property (nonatomic, readonly) CGFloat scale;
@end

static id FGReadCompositorProperty(id object, NSString *key) {
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

id FGComposedImage(id self, SEL _cmd, CGSize size, double scale) {
    // Keep the owner alive while its borrowed CGImage is being read.
    __attribute__((objc_precise_lifetime)) id original =
        ((id (*)(id, SEL, CGSize, double))FGOriginalComposedImage)(self, _cmd, size, scale);
    uint64_t state = 0;
    int status = notify_get_state(FGModeToken, &state);

    // Only the two highlight modes post-process. Off and Remove Highlights
    // preserve the result of the already-completed composition.
    if (status != NOTIFY_STATUS_OK || (state != 2 && state != 4)) return original;

    @try {
        id<FGComposedImageResult> imageResult = original;
        if (![imageResult respondsToSelector:@selector(CGImage)] ||
            ![imageResult respondsToSelector:@selector(scale)]) return original;

        id elements = FGReadCompositorProperty(self, @"elements");
        id primary = [elements respondsToSelector:@selector(firstObject)] ? [elements firstObject] : nil;
        id recipe = FGReadCompositorProperty(primary, @"recipe") ?:
                    FGReadCompositorProperty(self, @"recipe");
        Class appRecipeClass = objc_getClass("ISiOSAppRecipe");
        if (!appRecipeClass || ![recipe isKindOfClass:appRecipeClass]) return original;

        CGImageRef artwork = imageResult.CGImage;
        if (!artwork) return original;

        size_t w = CGImageGetWidth(artwork);
        size_t h = CGImageGetHeight(artwork);
        if (w == 0 || w != h || w >= 0x401) return original;
        CGFloat imageScale = imageResult.scale;
        if (!isfinite(imageScale) || imageScale <= 0) return original;

        // The resource pass has already prepared layered artwork for state 2.
        CGImageRef output = (state == 4 || FGHasLayeredPrimaryResource(primary))
            ? NGCreateRimmedImage(artwork)
            : NGCreateGlassedImage(artwork, 0);

        if (output) {
            @try {
                id image = FGWrapImage(output, imageScale);
                if (image) return image;
            } @finally {
                CGImageRelease(output);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[FlatGlass] composed render failed: %@", e.reason);
    }

    return original;
}
