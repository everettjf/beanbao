#import <Foundation/Foundation.h>
#import "BeanBaoBridge.h"

__attribute__((constructor)) static void BBStart(void) {
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
    // Delay startup until SpringBoard has entered its normal run loop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [[BeanBaoBridge shared] start]; });
}
