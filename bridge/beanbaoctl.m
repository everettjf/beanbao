#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>

static NSString *const BBSocket = @"/var/mobile/Library/Caches/BeanBao/bridge.sock";
static NSString *const BBTokenFile = @"/var/mobile/Library/Caches/BeanBao/bridge.token";

static BOOL WriteAll(int fd, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    while (remaining) {
        ssize_t written = write(fd, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        bytes += written;
        remaining -= (NSUInteger)written;
    }
    return YES;
}

static NSDictionary *Request(NSDictionary *request, NSString **failure) {
    int tokenFD = open(BBTokenFile.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (tokenFD < 0) {
        *failure = [NSString stringWithFormat:@"Bridge token unavailable (open errno %d)", errno];
        return nil;
    }
    char tokenBytes[65] = {0};
    ssize_t tokenLength = read(tokenFD, tokenBytes, 64);
    close(tokenFD);
    NSString *token = tokenLength == 64 ? [[NSString alloc] initWithBytes:tokenBytes length:64 encoding:NSUTF8StringEncoding] : nil;
    if (token.length != 64) { *failure = @"Bridge token unavailable (invalid length)"; return nil; }
    NSMutableDictionary *payload = [request mutableCopy];
    payload[@"token"] = token;
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data || data.length >= 65536) { *failure = @"Invalid or oversized request"; return nil; }
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { *failure = @"Cannot create socket"; return nil; }
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, BBSocket.fileSystemRepresentation, sizeof(address.sun_path));
    struct timeval timeout = {.tv_sec = 15, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd); *failure = @"Bridge is not running"; return nil;
    }
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    if (!WriteAll(fd, line)) { close(fd); *failure = @"Bridge write failed"; return nil; }
    NSMutableData *response = [NSMutableData data];
    uint8_t byte;
    while (response.length < 8 * 1024 * 1024) {
        ssize_t count = read(fd, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        if (byte == '\n') break;
        [response appendBytes:&byte length:1];
    }
    close(fd);
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) { *failure = @"Invalid bridge response"; return nil; }
    return parsed;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2 || argc > 3) {
            fprintf(stderr, "usage: beanbaoctl observe | beanbaoctl run '打开地图' | beanbaoctl '{JSON request}'\n");
            return 2;
        }
        NSString *arg = [NSString stringWithUTF8String:argv[1]];
        if ([arg isEqualToString:@"run"] && argc == 3) {
            NSString *task = [NSString stringWithUTF8String:argv[2]];
            NSDictionary<NSString *, NSString *> *targets = @{@"设置": @"com.apple.Preferences",
                                                              @"备忘录": @"com.apple.mobilenotes",
                                                              @"地图": @"com.apple.Maps",
                                                              @"通讯录": @"com.apple.MobileAddressBook"};
            NSMutableArray<NSString *> *matches = [NSMutableArray array];
            for (NSString *name in targets) if ([task containsString:name]) [matches addObject:targets[name]];
            if (matches.count != 1 || ![task hasPrefix:@"打开"]) {
                fprintf(stderr, "模拟代理只支持明确的‘打开设置/备忘录/地图/通讯录’任务\n"); return 2;
            }
            NSString *error = nil;
            NSDictionary *observation = Request(@{@"op": @"observe"}, &error);
            if (!observation || ![observation[@"ok"] boolValue]) {
                fprintf(stderr, "观察失败: %s\n", [((NSString *)(error ?: observation[@"error"] ?: @"未知错误")) UTF8String]); return 1;
            }
            NSDictionary *state = observation[@"device_state"];
            if (![state[@"locked_known"] boolValue] || [state[@"locked"] boolValue] ||
                ![state[@"screen_on_known"] boolValue] || ![state[@"screen_on"] boolValue]) {
                fprintf(stderr, "设备已锁定、屏幕关闭或状态未知\n"); return 1;
            }
            NSString *target = matches[0];
            if ([observation[@"frontmost_app"][@"bundleId"] isEqualToString:target]) {
                puts("目标 App 已在前台"); return 0;
            }
            NSString *observationID = observation[@"observation_id"];
            if (![observationID isKindOfClass:[NSString class]]) {
                fprintf(stderr, "缺少观察标识\n"); return 1;
            }
            NSDictionary *result = Request(@{@"op": @"act", @"observation_id": observationID,
                                             @"action": @"launch_app", @"bundle_id": target}, &error);
            if (!result || ![result[@"ok"] boolValue]) {
                fprintf(stderr, "启动失败: %s\n", [((NSString *)(error ?: result[@"error"] ?: @"未知错误")) UTF8String]); return 1;
            }
            puts("目标 App 已启动"); return 0;
        }
        if (argc != 2) { fprintf(stderr, "invalid arguments\n"); return 2; }
        NSDictionary *request = [arg isEqualToString:@"observe"] ? @{@"op": @"observe", @"ui": @YES} :
            [NSJSONSerialization JSONObjectWithData:[arg dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![request isKindOfClass:[NSDictionary class]]) {
            fprintf(stderr, "invalid JSON request\n"); return 2;
        }
        NSString *error = nil;
        NSDictionary *response = Request(request, &error);
        if (!response) {
            fprintf(stderr, "%s\n", (error ?: @"Request failed").UTF8String);
            return 1;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingPrettyPrinted error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return [response[@"ok"] boolValue] ? 0 : 1;
    }
}
