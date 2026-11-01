#import "BBAudit.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const char *BBAuditDirectory = "/var/mobile/Library/Application Support/BeanBao";
static const char *BBAuditPath = "/var/mobile/Library/Application Support/BeanBao/audit.jsonl";

NSDictionary *BBAuditRecord(NSString *event, NSString *app, NSString *action, NSString *result) {
    static NSSet<NSString *> *events, *apps, *actions, *results;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        events = [NSSet setWithArray:@[@"task", @"step"]];
        apps = [NSSet setWithArray:@[@"BeanBao", @"Settings", @"Notes", @"Maps", @"Contacts",
                                     @"设置", @"备忘录", @"地图", @"通讯录",
                                     @"com.apple.Preferences", @"com.apple.mobilenotes",
                                     @"com.apple.Maps", @"com.apple.MobileAddressBook"]];
        actions = [NSSet setWithArray:@[@"start", @"done", @"error", @"stopped",
                                        @"launch_app", @"tap", @"swipe", @"input_text",
                                        @"press_key", @"policy_block"]];
        results = [NSSet setWithArray:@[@"accepted", @"ok", @"failed", @"blocked"]];
    });
    if (![events containsObject:event] || ![apps containsObject:app] ||
        ![actions containsObject:action] || ![results containsObject:result]) return nil;
    return @{@"time": @([NSDate.date timeIntervalSince1970]), @"event": event,
             @"app": app, @"action": action, @"result": result};
}

void BBAudit(NSString *event, NSString *app, NSString *action, NSString *result) {
    if (getuid() != 501) return;
    NSDictionary *record = BBAuditRecord(event, app, action, result);
    if (!record) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json || json.length > 512) return;
    struct stat directory = {0};
    if (lstat(BBAuditDirectory, &directory)) {
        if (errno != ENOENT || (mkdir(BBAuditDirectory, 0700) && errno != EEXIST) ||
            lstat(BBAuditDirectory, &directory)) return;
    }
    if (!S_ISDIR(directory.st_mode) || directory.st_uid != 501 || (directory.st_mode & 077)) return;
    int fd = open(BBAuditPath, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) return;
    if (flock(fd, LOCK_EX)) { close(fd); return; }
    struct stat file = {0};
    if (fstat(fd, &file) || !S_ISREG(file.st_mode) || file.st_uid != 501 ||
        (file.st_mode & 077)) { flock(fd, LOCK_UN); close(fd); return; }
    if (file.st_size > 512 * 1024 && ftruncate(fd, 0)) { flock(fd, LOCK_UN); close(fd); return; }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *cursor = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) break;
        cursor += written;
        remaining -= (NSUInteger)written;
    }
    flock(fd, LOCK_UN);
    close(fd);
}
