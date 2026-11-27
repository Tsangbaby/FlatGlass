//
//  FGTypes.m
//  FlatGlass
//
//  Plain data holders. The only interesting bit is -dealloc releasing the
//  CGColorRefs that live inside NGGradient.colors, which are boxed on purpose
//  to avoid retaining cycles through CF types.
//

#import "FGTypes.h"

@implementation NGRendition
- (void)dealloc {
    // ARC handles the Objective-C members; nothing manual to do here.
}
@end

@implementation NGLayerRef
@end

@implementation NGCatalogIndex
@end

@implementation NGGradient

- (void)dealloc {
    // Colours are boxed CGColorRef pointers; release the ones we still own.
    for (id boxed in self.colors) {
        if ([boxed isKindOfClass:[NSValue class]]) {
            CGColorRef color = (CGColorRef)[(NSValue *)boxed pointerValue];
            if (color) CGColorRelease(color);
        }
    }
}

@end
