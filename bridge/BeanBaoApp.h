#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSDictionary *BBFrontmostApp(void);
FOUNDATION_EXPORT BOOL BBLaunchAllowedApp(NSString *bundleID, NSString **error);
FOUNDATION_EXPORT BOOL BBIsAllowedApp(NSString *bundleID);
FOUNDATION_EXPORT void BBOpenBeanBaoApp(void);
