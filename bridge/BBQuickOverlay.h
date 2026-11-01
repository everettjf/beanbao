#import <Foundation/Foundation.h>

@interface BBQuickOverlay : NSObject
+ (instancetype)shared;
- (BOOL)show;
- (BOOL)beginVoiceFromBundle:(NSString *)bundleID;
- (void)hide;
@end
