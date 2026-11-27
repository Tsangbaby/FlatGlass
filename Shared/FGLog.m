//
//  FGLog.m
//  FlatGlass
//

#import "FGLog.h"

FGLogBlock FGLogSink = nil;

void FGLogInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *env = getenv("FLATGLASS_DEBUG");
        if (env && env[0] != '\0') {
            FGLogSink = ^(NSString *message) {
                NSLog(@"[FlatGlass] %@", message);
            };
        }
    });
}
