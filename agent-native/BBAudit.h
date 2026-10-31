#import <Foundation/Foundation.h>

NSDictionary *BBAuditRecord(NSString *event, NSString *app, NSString *action, NSString *result);
void BBAudit(NSString *event, NSString *app, NSString *action, NSString *result);
