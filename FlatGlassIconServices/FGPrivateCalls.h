#ifndef FG_PRIVATE_CALLS_H
#define FG_PRIVATE_CALLS_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

// Local declarations only: no class references to private framework symbols.
@protocol FGPrivateImage <NSObject>
- (instancetype)initWithCGImage:(CGImageRef)image scale:(CGFloat)scale;
- (CGImageRef)CGImage;
- (CGFloat)scale;
@end

static inline BOOL FGEncodedTypeIs(const char *actual, const char *expected) {
    while (*actual && strchr("rnNoORV", *actual)) ++actual;
    if (strcmp(expected, "@") == 0) return actual[0] == '@' && actual[1] != '?';
    if (strcmp(expected, "^") == 0) return actual[0] == '^';
    return strcmp(actual, expected) == 0;
}

// args excludes self and _cmd. A mere respondsToSelector: is not an ABI check.
static inline BOOL FGMethodIs(Method method, unsigned args, const char *result,
                              const char *arg0, const char *arg1) {
    if (!method || method_getNumberOfArguments(method) != args + 2) return NO;
    char buf[128] = {0};
    method_getReturnType(method, buf, sizeof(buf) - 1);
    if (!FGEncodedTypeIs(buf, result)) return NO;
    if (arg0) {
        buf[0] = 0;
        method_getArgumentType(method, 2, buf, sizeof(buf) - 1);
        if (!FGEncodedTypeIs(buf, arg0)) return NO;
    }
    if (arg1) {
        buf[0] = 0;
        method_getArgumentType(method, 3, buf, sizeof(buf) - 1);
        if (!FGEncodedTypeIs(buf, arg1)) return NO;
    }
    return YES;
}

static inline Method FGGetMethod(id receiver, SEL sel) {
    return receiver ? class_getInstanceMethod(object_getClass(receiver), sel) : NULL;
}

static inline id FGPrivateObject(id receiver, SEL sel) {
    if (!FGMethodIs(FGGetMethod(receiver, sel), 0, "@", NULL, NULL)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, sel);
}

#endif
