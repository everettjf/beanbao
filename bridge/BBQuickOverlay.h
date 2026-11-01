#import <Foundation/Foundation.h>

@interface BBQuickOverlay : NSObject
+ (instancetype)shared;
- (BOOL)show;
- (BOOL)showAndStartDictation;
- (void)hide;
@end
