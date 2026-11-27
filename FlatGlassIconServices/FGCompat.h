//
//  FGCompat.h
//  FlatGlass
//
//  Runtime glue for the icon agent. The tweak deliberately avoids a hooking
//  framework: it locates the three private IconServices classes with
//  objc_getClass, validates the exact method signature it expects, and only
//  then swaps the implementation with class_replaceMethod. If anything does not
//  line up the tweak installs nothing and leaves a single line in the log.
//
//  That design is what makes the tweak "fail silent" on unsupported firmware
//  instead of crashing iconservicesagent — worth preserving exactly.
//

#ifndef FG_COMPAT_H
#define FG_COMPAT_H

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdbool.h>

/// TRUE when `m` looks like `- (id)imageForSize:(CGSize)size scale:(double)scale`:
/// exactly four arguments (self, _cmd, size, scale), object return type,
/// `{CGSize=dd}` for argument 2 and `d` for argument 3.
BOOL FGIsImageRenderer(Method m);

/// Resolves the private classes and installs the two replacement IMPs.
/// Returns YES when both (or at least one) replacement went in.
BOOL FGInstallHooks(void);

/// Re-reads the notify state and drops the on-disk icon cache when the mode
/// changed since the last run. `state` is the value published by the daemon.
void FGInvalidateCacheIfNeeded(uint64_t state, bool fromNotification);

/// The original implementations, captured before the swap. Used as the
/// fall-through path whenever the tweak cannot render (no stack, bad size,
/// unsupported appearance, or the user selected "off").
extern IMP FGOriginalResourceImage;
extern IMP FGOriginalComposedImage;

#endif /* FG_COMPAT_H */
