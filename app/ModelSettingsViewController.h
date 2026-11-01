#import <UIKit/UIKit.h>

@interface BBModelSettingsViewController : UIViewController
@property(nonatomic, copy) void (^onSave)(void);
@end
