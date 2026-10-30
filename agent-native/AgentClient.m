#import "AgentClient.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

NSDictionary *BBAgentRequest(NSDictionary *request) {
    if (![NSJSONSerialization isValidJSONObject:request]) return @{@"ok": @NO, @"error": @"请求格式无效"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    if (json.length >= 4096) return @{@"ok": @NO, @"error": @"请求过长"};
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return @{@"ok": @NO, @"error": @"无法创建连接"};
    int noSigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, "/var/mobile/Library/Caches/BeanBao/agent.sock", sizeof(address.sun_path));
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
        close(fd); return @{@"ok": @NO, @"error": @"BeanBao 服务未运行"};
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *cursor = line.bytes;
    NSUInteger remaining = line.length;
    while (remaining) {
        ssize_t wrote = write(fd, cursor, remaining);
        if (wrote < 0 && errno == EINTR) continue;
        if (wrote <= 0) { close(fd); return @{@"ok": @NO, @"error": @"请求发送失败"}; }
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
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{@"ok": @NO, @"error": @"服务响应无效"};
}
