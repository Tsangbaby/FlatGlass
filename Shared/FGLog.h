//
//  FGLog.h
//  FlatGlass
//
//  The original binary keeps a single global block pointer (`_NGLog`) and every
//  diagnostic call site does `if (NGLog) NGLog(fmt, ...)`.  When the pointer is
//  NULL the whole logging path disappears, which is why a shipping device logs
//  nothing at all.  We reproduce that: the pointer stays NULL unless the
//  environment variable FLATGLASS_DEBUG is set on the process.
//

#ifndef FG_LOG_H
#define FG_LOG_H

#import <Foundation/Foundation.h>

typedef void (^FGLogBlock)(NSString *message);

// Global sink. NULL == silent. Assigned once in FGLogInit().
extern FGLogBlock FGLogSink;

// Reads FLATGLASS_DEBUG out of the environment. Safe to call more than once.
void FGLogInit(void);

// Unconditionally build the message and hand it to the sink when one exists.
// Call sites are cheap when logging is off: the check happens before formatting
// only if you use FGLogf(), so prefer that macro in hot paths.
#define FGLogf(fmt, ...) do {                                       \
    if (FGLogSink) {                                                \
        FGLogSink([NSString stringWithFormat:(fmt), ##__VA_ARGS__]); \
    }                                                               \
} while (0)

#endif /* FG_LOG_H */
