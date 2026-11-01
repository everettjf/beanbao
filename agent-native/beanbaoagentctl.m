#import "AgentClient.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSDictionary *request = nil;
        if (argc == 2 && !strcmp(argv[1], "status")) request = @{@"op": @"status"};
        else if (argc == 2 && !strcmp(argv[1], "stop")) request = @{@"op": @"stop"};
        else if (argc == 3 && !strcmp(argv[1], "start"))
            request = @{@"op": @"start", @"task": [NSString stringWithUTF8String:argv[2]]};
        else if (argc == 4 && !strcmp(argv[1], "start") && !strcmp(argv[2], "--claude"))
            request = @{@"op": @"start", @"task": [NSString stringWithUTF8String:argv[3]]};
        else { fputs("usage: beanbaoagentctl status | stop | start '打开地图'\n", stderr); return 2; }
        NSDictionary *reply = BBAgentRequest(request);
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        puts([[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding].UTF8String);
        return [reply[@"ok"] boolValue] ? 0 : 1;
    }
}
