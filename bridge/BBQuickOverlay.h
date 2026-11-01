#import <Foundation/Foundation.h>

@interface BBQuickOverlay : NSObject
+ (instancetype)shared;
- (BOOL)show;
- (void)hide;
@end
