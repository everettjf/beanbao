#import "AgentClient.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

NSDictionary *BBAgentRequest(NSDictionary *request) {
    if (![NSJSONSerialization isValidJSONObject:request]) return @{@"ok": @NO, @"error": @"Invalid request format"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSUInteger requestLimit = [@[@"delivery_observe", @"delivery_plan",
                                 @"delivery_verify_action", @"delivery_action_result"]
        containsObject:request[@"op"]] ?
        65536 : 4096;
    if (json.length >= requestLimit) return @{@"ok": @NO, @"error": @"Request is too long"};
    // RootHide's SSH shell has a different /var/mobile view from launchd and
    // SpringBoard. The app can use the first path; its CLI can use /rootfs.
    const char *paths[] = {"/var/mobile/Library/Caches/BeanBao/agent.sock",
                           "/rootfs/private/var/mobile/Library/Caches/BeanBao/agent.sock"};
    int fd = -1;
    for (NSUInteger i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return @{@"ok": @NO, @"error": @"Could not create a connection"};
        int noSigpipe = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
        struct timeval timeout = {.tv_sec = 3};
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, paths[i], sizeof(address.sun_path));
        if (!connect(fd, (struct sockaddr *)&address, sizeof(address))) break;
        close(fd);
        fd = -1;
    }
    if (fd < 0) return @{@"ok": @NO, @"error": @"BeanBao service is not running"};
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *cursor = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining) {
        ssize_t wrote = write(fd, cursor, remaining);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { close(fd); return @{@"ok": @NO, @"error": @"Could not send the request"}; }
        cursor += wrote; remaining -= (NSUInteger)wrote;
    }
    NSMutableData *reply = [NSMutableData data];
    char byte = 0;
    while (reply.length < 4096) {
        ssize_t count = read(fd, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0 || byte == '\n') break;
        [reply appendBytes:&byte length:1];
    }
    close(fd);
    id parsed = [NSJSONSerialization JSONObjectWithData:reply options:0 error:nil];
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{@"ok": @NO, @"error": @"Invalid service response"};
}
