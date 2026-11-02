#import <UIKit/UIKit.h>

/// Browser surface for the first delivery adapter. Page snapshots are held in
/// memory and returned only to the caller; login pages are never inspected.
@interface BBDeliveryBrowserViewController : UIViewController
- (void)captureCurrentPageWithCompletion:(void (^)(NSDictionary *snapshot))completion;
@end
