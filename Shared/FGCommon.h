//
//  FGCommon.h
//  FlatGlass — shared definitions across the four components
//
//  Reconstructed from local.lumid.flatglass 1.8.4 (iphoneos-arm64).
//  Everything in this file is verified against the shipped binaries:
//  the notify names, the preference domain and the render layouts.
//

#ifndef FG_COMMON_H
#define FG_COMMON_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// ---------------------------------------------------------------------------
// Preferences (the Settings pane owns persisted user choices)
// ---------------------------------------------------------------------------

#define FG_PREFS_DOMAIN   @"local.lumid.flatglass"
#define FG_PREFS_PATH     @"/var/mobile/Library/Preferences/local.lumid.flatglass.plist"

// "Mode" holds an NSNumber. The daemon publishes Mode + 1, reserving state 0
// for no published mode. These values match the Settings picker, not its order.
typedef NS_ENUM(NSInteger, FGMode) {
    FGModeFlat          = 0,   // Remove Highlights — flatten every icon layer
    FGModeEdgeArtwork   = 1,   // Edge and Artwork — rim plus artwork highlight
    FGModeOff           = 2,   // Off — leave system rendering untouched
    FGModeEdge          = 3,   // Edge Only — soft highlight around the rim
};

static inline BOOL FGDecodePreferenceMode(id value, NSInteger *mode) {
    if (!mode || ![value isKindOfClass:[NSNumber class]]) return NO;
    CFNumberRef number = (__bridge CFNumberRef)value;
    NSInteger decoded = 0;
    if (CFGetTypeID(number) != CFNumberGetTypeID() || CFNumberIsFloatType(number) ||
        !CFNumberGetValue(number, kCFNumberNSIntegerType, &decoded) || decoded < 0 || decoded > 3)
        return NO;
    *mode = decoded;
    return YES;
}

// ---------------------------------------------------------------------------
// Darwin notify chain
//
//   settings pane  --(persist mode + notify_post)-------->  daemon
//   daemon          --(notify_set_state)------------------->  iconservicesagent
//                                                             SpringBoard
//
// The agent registers the state and re-renders; SpringBoard just reloads the
// visible icon views in batches. Both consumers key off the same name.
// ---------------------------------------------------------------------------

#define FG_NOTIFY_MODE           "local.lumid.flatglass.iconservices-mode"
#define FG_NOTIFY_SETTINGS       "local.lumid.flatglass.settings-changed"

// Bookkeeping file the agent drops next to the icon caches. Its only job is to
// carry the last applied token across process restarts, so a relaunch of
// iconservicesagent does not re-render everything for nothing.
#define FG_MODE_STAMP            @"/var/mobile/Library/Caches/com.apple.IconsCache/.flatglass-mode"

/// Darwin notify token registered for FG_NOTIFY_MODE. Zero until the agent
/// installs its handler; callers must treat zero as "no state available".
extern int FGModeToken;

// ---------------------------------------------------------------------------
// Icon Services render layouts
//
// An NGRendition's `layout` field tells the compositor how to treat the record.
// Only the handful below matter for this tweak; the numbers come straight from
// the binaries and line up with IconServices' own constants.
// ---------------------------------------------------------------------------

typedef NS_ENUM(uint32_t, FGLayout) {
    FGLayoutUnknown         = 0,
    FGLayoutImage           = 9,      // raw bitmap / SVG payload
    FGLayoutSolidFill       = 1009,   // flat colour, painted as a rect
    FGLayoutComposite       = 1020,   // group: recurse into children
    FGLayoutGradient        = 1021,   // gradient (ARGG / ARGA / ARGN)
    FGLayoutLayered         = 1017,   // layered artwork, needs colour matching
};

#endif /* FG_COMMON_H */
