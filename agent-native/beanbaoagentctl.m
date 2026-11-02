#import "AgentClient.h"

static NSDictionary *BBSnapshotArgument(const char *text) {
    if (!text) return nil;
    NSData *data = [[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length >= 65536) return nil;
    NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [snapshot isKindOfClass:NSDictionary.class] ? snapshot : nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (argc == 2 && !strcmp(argv[1], "status")) request = @{@"op": @"status"};
        else if (argc == 2 && !strcmp(argv[1], "stop")) request = @{@"op": @"stop"};
        else if (argc == 3 && !strcmp(argv[1], "start"))
            request = @{@"op": @"start", @"task": [NSString stringWithUTF8String:argv[2]]};
        else if (argc == 4 && !strcmp(argv[1], "start") && !strcmp(argv[2], "--claude"))
            request = @{@"op": @"start", @"task": [NSString stringWithUTF8String:argv[3]]};
        else if (argc == 3 && !strcmp(argv[1], "inspect-delivery")) {
            NSDictionary *snapshot = BBSnapshotArgument(argv[2]);
            if (!snapshot) {
                fputs("invalid delivery snapshot\n", stderr);
                return 2;
            }
            request = @{@"op": @"delivery_observe", @"snapshot": snapshot};
        }
        else if (argc == 4 && !strcmp(argv[1], "plan-delivery")) {
            NSDictionary *snapshot = BBSnapshotArgument(argv[3]);
            if (!snapshot) {
                fputs("invalid delivery snapshot\n", stderr);
                return 2;
            }
            request = @{@"op": @"delivery_plan", @"task": [NSString stringWithUTF8String:argv[2]],
                        @"snapshot": snapshot};
        }
        else if (argc == 5 && (!strcmp(argv[1], "verify-delivery") ||
                               !strcmp(argv[1], "complete-delivery"))) {
            NSDictionary *snapshot = BBSnapshotArgument(argv[4]);
            if (!snapshot) { fputs("invalid delivery snapshot\n", stderr); return 2; }
            request = @{@"op": !strcmp(argv[1], "verify-delivery") ?
                            @"delivery_verify_action" : @"delivery_action_result",
                        @"task_id": [NSString stringWithUTF8String:argv[2]],
                        @"service_id": [NSString stringWithUTF8String:argv[3]],
                        @"snapshot": snapshot};
        }
        else { fputs("usage: beanbaoagentctl status | stop | start 'Open Maps' | inspect-delivery '<snapshot JSON>' | plan-delivery 'Find lunch' '<snapshot JSON>' | verify-delivery TASK_ID SERVICE_ID '<snapshot JSON>' | complete-delivery TASK_ID SERVICE_ID '<snapshot JSON>'\n", stderr); return 2; }
        NSDictionary *reply = BBAgentRequest(request);
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        puts([[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding].UTF8String);
        return [reply[@"ok"] boolValue] ? 0 : 1;
    }
}
