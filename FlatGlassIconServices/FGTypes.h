//
//  FGTypes.h
//  FlatGlass
//
//  The four model objects the icon agent builds while walking an ISTC stack.
//  Field names, ordering and types were recovered from the shipped dylib's
//  property lists (@property accessors are all present, so the layout is
//  authoritative rather than guessed).
//
//  These are *our* copies of IconServices' private classes. The tweak never
//  hands them back to the system, so ivar offsets do not have to match Apple's
//  objects — only our own reader/writer pair has to agree.
//

#ifndef FG_TYPES_H
#define FG_TYPES_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry in a theme catalog: either a stack node, a fill, a colour record
/// or a bitmap payload, discriminated by `layout`.
@interface NGRendition : NSObject
@property (nonatomic, copy,   nullable) NSData   *key;      // keyList: packed {uint16 id, uint16 value}
@property (nonatomic, copy,   nullable) NSData   *csi;      // raw record payload
@property (nonatomic, copy,   nullable) NSString *name;
@property (nonatomic, assign) uint32_t layout;
@property (nonatomic, assign) uint32_t pixelFormat;
@property (nonatomic, assign) uint32_t width;
@property (nonatomic, assign) uint32_t height;
@end

/// One drawing instruction inside a composite node.
@interface NGLayerRef : NSObject
@property (nonatomic, assign) CGRect   frame;
@property (nonatomic, assign) uint32_t blendMode;
@property (nonatomic, assign) uint32_t flags;
@property (nonatomic, assign) float    opacity;
@property (nonatomic, assign) float    blur;
@property (nonatomic, assign) float    translucency;
@property (nonatomic, copy,   nullable) NSData   *keyList;
@property (nonatomic, copy,   nullable) NSString *fill;
@property (nonatomic, copy,   nullable) NSString *lighting;
@property (nonatomic, copy,   nullable) NSString *specular;
@property (nonatomic, assign) uint32_t shadowStyle;
@property (nonatomic, assign) float    shadowOpacity;
@end

/// The parsed catalog: every rendition plus the appearance-token maps used to
/// pick the right variant for light / dark / tinted Home Screen.
@interface NGCatalogIndex : NSObject
@property (nonatomic, strong, nullable) NSArray<NGRendition *> *renditions;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSNumber *> *tokens;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, NSNumber *> *appearances;
@end

/// A gradient fill (layout 1021). `colors` holds CGColorRef boxed into NSValue
/// by the renderer; `stops` holds NSNumber floats in the same order.
@interface NGGradient : NSObject
@property (nonatomic, assign) uint32_t type;
@property (nonatomic, assign) CGPoint  start;
@property (nonatomic, assign) CGPoint  end;
@property (nonatomic, strong, nullable) NSArray *colors;
@property (nonatomic, strong, nullable) NSArray<NSNumber *> *stops;
@end

NS_ASSUME_NONNULL_END

#endif /* FG_TYPES_H */
