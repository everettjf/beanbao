#import "AgentClient.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>

static NSString *BBDeliveryPairingToken;

static void BBConfigureAgentSocket(int fd) {
    int noSigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

void BBSetDeliveryPairingToken(NSString *token) {
    @synchronized(NSBundle.mainBundle) { BBDeliveryPairingToken = [token copy]; }
}

NSDictionary *BBAgentRequest(NSDictionary *request) {
    if (![NSJSONSerialization isValidJSONObject:request]) return @{@"ok": @NO, @"error": @"Invalid request format"};
    BOOL deliveryBrowser = [NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"dev.beanbao.deliverybrowser"];
    if (deliveryBrowser) {
        NSString *token = nil;
        @synchronized(NSBundle.mainBundle) { token = BBDeliveryPairingToken; }
        if (token.length != 64)
            return @{@"ok": @NO, @"error": @"Open BeanBao to connect the delivery browser"};
        NSMutableDictionary *paired = [request mutableCopy];
        paired[@"delivery_token"] = token;
        request = paired;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSUInteger requestLimit = [@[@"delivery_observe", @"delivery_plan",
                                 @"delivery_verify_action", @"delivery_action_result"]
        containsObject:request[@"op"]] ?
        65536 : 4096;
    if (json.length >= requestLimit) return @{@"ok": @NO, @"error": @"Request is too long"};
    // RootHide's SSH shell has a different /var/mobile view from launchd and
    // SpringBoard. The app can use the first path; its CLI can use /rootfs.
    NSArray<NSString *> *paths = @[@"/var/mobile/Library/Caches/BeanBao/agent.sock",
        @"/rootfs/private/var/mobile/Library/Caches/BeanBao/agent.sock"];
    int fd = -1;
    if (deliveryBrowser) {
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return @{@"ok": @NO, @"error": @"Could not create a connection"};
        BBConfigureAgentSocket(fd);
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(47813);
        if (connect(fd, (struct sockaddr *)&address, sizeof(address))) {
            close(fd); fd = -1;
        }
    }
    for (NSString *path in deliveryBrowser ? @[] : paths) {
        fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return @{@"ok": @NO, @"error": @"Could not create a connection"};
        BBConfigureAgentSocket(fd);
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        if (strlcpy(address.sun_path, path.fileSystemRepresentation,
                    sizeof(address.sun_path)) >= sizeof(address.sun_path)) {
            close(fd); fd = -1; continue;
        }
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
