#import <Foundation/Foundation.h>

// Display-only summaries derived from the Agent's private, content-free audit.
NSArray<NSDictionary *> *BBRecentActivity(NSUInteger limit);
NSArray<NSDictionary *> *BBActivityFromAuditData(NSData *data, NSUInteger limit);
