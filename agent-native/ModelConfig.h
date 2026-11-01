#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSDictionary *BBModelLoad(void);
FOUNDATION_EXPORT NSDictionary *BBModelProfile(NSDictionary *config, NSString *provider);
FOUNDATION_EXPORT NSString *BBModelProviderName(NSString *provider);
FOUNDATION_EXPORT NSString *BBModelReadKey(NSString *provider);
FOUNDATION_EXPORT BOOL BBModelSave(NSString *provider, NSString *model,
                                   NSString *endpoint, NSString *newKey, NSString **error);
