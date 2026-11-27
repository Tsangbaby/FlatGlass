#ifndef FG_PREFERENCES_H
#define FG_PREFERENCES_H

#include <stdbool.h>
#include <stdint.h>

// Root.plist 的显示顺序是 0、3、1、2；notify state 则是 Mode + 1。
typedef enum {
    FGModeRemove = 0,
    FGModeArtwork = 1,
    FGModeOff = 2,
    FGModeEdge = 3,
} FGMode;

static inline bool FGDecodeMode(double value, FGMode *mode) {
    // 先检查范围，再转换；避免宽整数回绕、NaN 或小数截断为有效档位。
    if (!(value >= FGModeRemove && value <= FGModeEdge) || value != (int)value) return false;
    *mode = (FGMode)value;
    return true;
}

static inline uint64_t FGStateForMode(FGMode mode) {
    return (uint64_t)mode + 1;
}

#ifdef __OBJC__
#import <Foundation/Foundation.h>

#if defined(FG_ROOTHIDE) && FG_ROOTHIDE
#include <roothide.h>
#endif

static NSString *const FGModeKey = @"Mode";
static const char FGSettingsChangedNotification[] = "local.lumid.flatglass.settings-changed";
static const char FGModeNotification[] = "local.lumid.flatglass.iconservices-mode";

static inline NSString *FGJailPath(NSString *path) {
#if defined(FG_ROOTHIDE) && FG_ROOTHIDE
    return jbroot(path);
#else
    return [@"/var/jb" stringByAppendingString:path];
#endif
}

static inline NSString *FGPreferencesPath(void) {
    // 首轮不回读、复制或删除旧偏好；Prefs 与 daemon 只用当前方案的路径。
#if defined(FG_ROOTHIDE) && FG_ROOTHIDE
    return jbroot(@"/var/mobile/Library/Preferences/local.lumid.flatglass.plist");
#else
    return @"/var/mobile/Library/Preferences/local.lumid.flatglass.plist";
#endif
}

static inline bool FGDecodePreferenceMode(id value, FGMode *mode) {
    return [value isKindOfClass:[NSNumber class]] && FGDecodeMode([value doubleValue], mode);
}

static inline FGMode FGReadMode(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:FGPreferencesPath()];
    FGMode mode = FGModeRemove;
    FGDecodePreferenceMode(prefs[FGModeKey], &mode);
    return mode;
}
#endif // __OBJC__

#endif // FG_PREFERENCES_H
