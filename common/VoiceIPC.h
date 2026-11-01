#import <Foundation/Foundation.h>

FOUNDATION_EXPORT BOOL BBVoiceWrite(NSString *kind, NSDictionary *payload);
FOUNDATION_EXPORT NSDictionary *BBVoiceRead(NSString *kind);
FOUNDATION_EXPORT void BBVoiceRemove(NSString *kind);
FOUNDATION_EXPORT BOOL BBVoiceValidSession(NSString *sessionID);
