//
//  FGWrap.h
//  FlatGlass
//
//  Two small helpers that live on the boundary between our rendering code and
//  IconServices' own objects.
//

#ifndef FG_WRAP_H
#define FG_WRAP_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/// Wraps a CGImage in whatever class IconServices expects back from
/// -imageForSize:scale: (IFImage on every shipping iOS 15+). Returns nil when
/// the class is missing or does not accept the initialiser.
id FGWrapImage(CGImageRef image, CGFloat scale);

/// YES when the compositor element's provider returns a layered primary
/// resource. In Edge and Artwork mode, that resource has already received
/// the artwork pass; composition only needs the rim.
BOOL FGHasLayeredPrimaryResource(id resource);

#endif /* FG_WRAP_H */
