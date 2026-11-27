// Native macOS integration test of the two CGImage entry points, not the hook.
#import "FGInternal.h"
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #c); exit(1); } } while (0)

// The only catalog dependency in FGGlass.m. No CoreUI/private catalog or I/O.
CGImageRef NGCreateFlatIcon(id catalog, NSString *name, uint32_t appearance, size_t px) {
    (void)catalog; (void)name; (void)appearance; (void)px;
    return NULL;
}

static CGContextRef bitmap(int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CHECK(cs);
    CGContextRef c = CGBitmapContextCreate(NULL, w, h, 8, 0, cs,
        kCGBitmapByteOrder32Big | (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    CHECK(c);
    return c;
}

static CGImageRef fixture(int w, int h, int rounded, int light) {
    CGContextRef c = bitmap(w, h);
    CGRect frame = CGRectMake(0, 0, w, h);
    CGContextClearRect(c, frame);
    CGContextSetRGBFillColor(c, light ? .92 : .22, light ? .9 : .46, light ? .86 : .58, 1);
    if (rounded) {
        CGPathRef p = CGPathCreateWithRoundedRect(frame, .24*w, .24*h, NULL);
        CHECK(p); CGContextAddPath(c, p); CGContextFillPath(c); CGPathRelease(p);
    } else CGContextFillRect(c, frame);
    // Asymmetric artwork catches flipped rows/channels. The square stays matte;
    // the translucent tile in the rounded image catches double premultiplication.
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextSetRGBFillColor(c, .72, .28, .14, rounded ? .65 : 1);
    CGContextFillRect(c, CGRectMake(w/3, h*3/8, w/7, h/8));
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c); CHECK(img); return img;
}

static CGContextRef readback(CGImageRef img, int n) {
    CHECK(img && CGImageGetWidth(img) == (size_t)n && CGImageGetHeight(img) == (size_t)n);
    CGContextRef c = bitmap(n,n);
    CGContextSetBlendMode(c, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0,0,n,n), img);
    return c;
}

static void checkShape(int n) {
    float *s = FGIconShape(n); CHECK(s);
    // The second cubic's midpoint hits the diagonal ~67.16/1024 from the corner.
    // The old transposed path crosses beyond 89/1024. Avoid AA boundary pixels.
    for (int j=0; j<2; j++) for (int i=0; i<2; i++) {
        int a=n/20, b=n*8/100;
        CHECK(s[(j?n-1-a:a)*n+(i?n-1-a:a)] < .1f);
        CHECK(s[(j?n-1-b:b)*n+(i?n-1-b:b)] > .9f);
    }
    CHECK(s[n*(n/2)+n/2] > .99f); free(s);
}

static void compare(int n, int rounded, int light, int glass) {
    CGImageRef src = fixture(n,n,rounded,light);
    CGImageRef out = glass ? NGCreateGlassedImage(src) : NGCreateRimmedImage(src);
    CGContextRef before = readback(src,n), after = readback(out,n);
    size_t sb = CGBitmapContextGetBytesPerRow(before), sa = CGBitmapContextGetBytesPerRow(after);
    const uint8_t *b = CGBitmapContextGetData(before), *a = CGBitmapContextGetData(after);
    int edge=0, center=0, badAlpha=0, badPremul=0, partial=0;
    for (int y=0;y<n;y++) for (int x=0;x<n;x++) {
        const uint8_t *p=b+y*sb+x*4, *q=a+y*sa+x*4;
        int diff=0;
        for (int k=0;k<3;k++) {
            int d=abs(p[k]-q[k]); if (d>diff) diff=d;
            if (q[k]>q[3]) ++badPremul;
        }
        int middle=x>=n/4 && x<3*n/4 && y>=n/4 && y<3*n/4;
        if (p[3] != q[3]) ++badAlpha;
        if (p[3]>0 && p[3]<255) ++partial;
        if (middle && diff>1) ++center;
        if ((x<n/8 || y<n/8 || x>=n-n/8 || y>=n-n/8) && p[3]==255 && q[3]==255 && diff>=2) ++edge;
    }
    fprintf(stderr,"%d %s %s %s: changed opaque edge=%d center=%d alpha mismatch=%d\n",n,
        rounded?"rounded":"square", light?"light":"matte",glass?"glassed":"rimmed",edge,center,badAlpha);
    CHECK(rounded ? (partial > 0 && b[3] == 0) : (partial == 0 && b[3] == 255));
    CHECK(!badAlpha && !badPremul && !center && edge>=n/4);
    CGContextRelease(before); CGContextRelease(after); CGImageRelease(src); CGImageRelease(out);
}

int main(void) { @autoreleasepool {
    CHECK(!NGCreateRimmedImage(NULL) && !NGCreateGlassedImage(NULL));
    CGImageRef small=fixture(7,7,0,0), rect=fixture(120,119,0,0), sub16=fixture(15,15,0,0);
    CHECK(!NGCreateRimmedImage(small) && !NGCreateGlassedImage(sub16));
    CHECK(!NGCreateRimmedImage(rect) && !NGCreateGlassedImage(rect));
    CGImageRelease(small); CGImageRelease(sub16); CGImageRelease(rect);
    CHECK(!NGCreateGlassIcon(@1,@"fixture",0,120) && !NGCreateGlassIconContent(@1,@"fixture",0,120));
    for (int n=120;n<=180;n+=60) {
        checkShape(n);
        for (int r=0;r<=1;r++) for (int l=0;l<=1;l++) for (int g=0;g<=1;g++) compare(n,r,l,g);
    }
    puts("CoreGraphics contour integration passed.");
} return 0; }
