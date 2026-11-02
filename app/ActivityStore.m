#import "ActivityStore.h"
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const BBAuditPath = @"/var/mobile/Library/Application Support/BeanBao/audit.jsonl";

static NSString *BBActivityTitle(NSString *app, BOOL enteredText, NSString *state) {
    if ([app isEqualToString:@"ResearchPDF"] || [app isEqualToString:@"ResearchMailDraft"])
        return [state isEqualToString:@"waiting_for_user"] ? @"Review research email" : @"Created research PDF";
    if ([app isEqualToString:@"AppStoreReview"])
        return [state isEqualToString:@"done"] ? @"Installed App Store app" : @"Review App Store listing";
    if ([app isEqualToString:@"Maps"] || [app isEqualToString:@"地图"])
        return enteredText ? @"Searched Maps" :
            ([state isEqualToString:@"done"] ? @"Opened Maps" : @"Maps task");
    if ([app isEqualToString:@"Notes"] || [app isEqualToString:@"备忘录"])
        return enteredText ? @"Created a note" :
            ([state isEqualToString:@"done"] ? @"Opened Notes" : @"Notes task");
    if ([app isEqualToString:@"Contacts"] || [app isEqualToString:@"通讯录"])
        return [state isEqualToString:@"done"] ? @"Opened Contacts" : @"Contacts task";
    if ([app isEqualToString:@"Settings"] || [app isEqualToString:@"设置"])
        return [state isEqualToString:@"done"] ? @"Opened Settings" : @"Settings task";
    return @"Task";
}

NSArray<NSDictionary *> *BBActivityFromAuditData(NSData *data, NSUInteger limit) {
    if (!data.length || !limit || data.length > 512 * 1024 + 1024) return @[];
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    for (NSString *line in [body componentsSeparatedByString:@"\n"]) {
        NSData *encoded = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!encoded.length || encoded.length > 512) continue;
        NSDictionary *record = [NSJSONSerialization JSONObjectWithData:encoded options:0 error:nil];
        if (![record isKindOfClass:NSDictionary.class]) continue;
        NSString *event = record[@"event"], *action = record[@"action"];
        NSString *app = record[@"app"];
        NSNumber *time = record[@"time"];
        if (![event isKindOfClass:NSString.class] || ![action isKindOfClass:NSString.class] ||
            ![app isKindOfClass:NSString.class] || ![time isKindOfClass:NSNumber.class]) continue;
        if ([event isEqualToString:@"task"] && [action isEqualToString:@"start"]) {
            if (current) [items addObject:[current copy]];
            current = [@{@"app": app, @"time": time, @"state": @"running", @"entered_text": @NO} mutableCopy];
        } else if (current && [event isEqualToString:@"step"] &&
                   [action isEqualToString:@"input_text"] && [record[@"result"] isEqualToString:@"ok"]) {
            current[@"entered_text"] = @YES;
        } else if (current && [event isEqualToString:@"task"] &&
                   [action isEqualToString:@"waiting_for_user"]) {
            current[@"state"] = @"waiting_for_user";
        } else if (current && [event isEqualToString:@"task"] &&
                   [@[@"done", @"error", @"stopped"] containsObject:action]) {
            current[@"state"] = action;
            current[@"end_time"] = time;
            [items addObject:[current copy]];
            current = nil;
        }
    }
    if (current) [items addObject:[current copy]];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    for (NSDictionary *item in items.reverseObjectEnumerator) {
        NSString *state = item[@"state"];
        NSMutableDictionary *display = [@{@"title": BBActivityTitle(item[@"app"], [item[@"entered_text"] boolValue], state),
            @"time": item[@"time"], @"state": state} mutableCopy];
        if (item[@"end_time"]) display[@"end_time"] = item[@"end_time"];
        [result addObject:display];
        if (result.count >= limit) break;
    }
    return result;
}

NSArray<NSDictionary *> *BBRecentActivity(NSUInteger limit) {
    int fd = open(BBAuditPath.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return @[];
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 077) || info.st_size < 0 || info.st_size > 512 * 1024 + 1024) {
        close(fd);
        return @[];
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    uint8_t *cursor = data.mutableBytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t count = read(fd, cursor, remaining);
        if (count <= 0) { close(fd); return @[]; }
        cursor += count;
        remaining -= (NSUInteger)count;
    }
    close(fd);
    return BBActivityFromAuditData(data, limit);
}
