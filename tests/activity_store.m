#import <Foundation/Foundation.h>
#import "../app/ActivityStore.h"

static BOOL Check(BOOL condition, NSString *message) {
    if (!condition) fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    return condition;
}

int main(void) {
    @autoreleasepool {
        NSString *audit =
            @"{\"event\":\"task\",\"app\":\"Contacts\",\"action\":\"start\",\"time\":1}\n"
             "{\"event\":\"task\",\"app\":\"Contacts\",\"action\":\"done\",\"time\":2}\n"
             "{\"event\":\"task\",\"app\":\"Notes\",\"action\":\"start\",\"time\":3}\n"
             "{\"event\":\"step\",\"app\":\"com.apple.mobilenotes\",\"action\":\"input_text\",\"result\":\"ok\",\"time\":4}\n"
             "{\"event\":\"task\",\"app\":\"Notes\",\"action\":\"done\",\"time\":5}\n"
             "{\"event\":\"task\",\"app\":\"Maps\",\"action\":\"start\",\"time\":6}\n"
             "{\"event\":\"step\",\"app\":\"com.apple.Maps\",\"action\":\"input_text\",\"result\":\"ok\",\"time\":7}\n"
             "{\"event\":\"task\",\"app\":\"Maps\",\"action\":\"error\",\"time\":8}\n";
        NSArray *items = BBActivityFromAuditData([audit dataUsingEncoding:NSUTF8StringEncoding], 3);
        if (!Check(items.count == 3, @"three task starts pair with terminal events") ||
            !Check([items[0][@"title"] isEqualToString:@"Searched Maps"] &&
                   [items[0][@"state"] isEqualToString:@"error"], @"Maps search failure is shown") ||
            !Check([items[1][@"title"] isEqualToString:@"Created a note"] &&
                   [items[1][@"state"] isEqualToString:@"done"], @"note creation is shown") ||
            !Check([items[2][@"title"] isEqualToString:@"Opened Contacts"], @"open task is shown") ||
            !Check(BBActivityFromAuditData([audit dataUsingEncoding:NSUTF8StringEncoding], 1).count == 1,
                   @"limit is respected") ||
            !Check([BBActivityFromAuditData([@"{\"event\":\"task\",\"app\":\"Maps\",\"action\":\"start\",\"time\":9}\n"
                "{\"event\":\"task\",\"app\":\"Maps\",\"action\":\"error\",\"time\":10}\n"
                dataUsingEncoding:NSUTF8StringEncoding], 1)[0][@"title"] isEqualToString:@"Maps task"],
                   @"failed search before input is not called an app open") ||
            !Check(![items.description containsString:@"input_text"], @"low-level audit steps stay hidden")) return 1;
        NSString *mailAudit = @"{\"event\":\"task\",\"app\":\"ResearchMailDraft\",\"action\":\"start\",\"time\":11}\n"
            "{\"event\":\"task\",\"app\":\"ResearchMailDraft\",\"action\":\"waiting_for_user\",\"time\":12}\n";
        NSArray *waiting = BBActivityFromAuditData([mailAudit dataUsingEncoding:NSUTF8StringEncoding], 1);
        if (!Check(waiting.count == 1 && [waiting[0][@"state"] isEqualToString:@"waiting_for_user"] &&
                   [waiting[0][@"title"] isEqualToString:@"Review research email"],
                   @"research email remains visibly pending until reviewed")) return 1;
        puts("PASS: private audit maps to content-free activity");
    }
    return 0;
}
