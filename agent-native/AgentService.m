#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <spawn.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <mach-o/dyld.h>

extern char **environ;

static const char *BBServiceSocket = "/var/mobile/Library/Caches/BeanBao/agent.sock";

@interface BBServiceState : NSObject
@property(nonatomic) pid_t child;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *app;
@property(nonatomic) BOOL stopping;
@end
@implementation BBServiceState
@end

static BBServiceState *BBState;

static NSString *BBAllowedTarget(NSString *task) {
    if ([task isEqualToString:@"打开设置"]) return @"设置";
    if ([task isEqualToString:@"打开备忘录"]) return @"备忘录";
    if ([task isEqualToString:@"打开地图"]) return @"地图";
    if ([task hasPrefix:@"在地图搜索"] && task.length > 5 && task.length <= 55 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        return @"地图";
    return nil;
}

static NSDictionary *BBStatus(void) {
    @synchronized (BBState) {
        return @{@"ok": @YES, @"phase": BBState.phase ?: @"idle",
                 @"message": BBState.message ?: @"",
                 @"app": BBState.app ?: @"", @"running": @(BBState.child > 0)};
    }
}

static void BBWaitForChild(pid_t child, int readFD, NSUInteger generation) {
    NSMutableData *output = [NSMutableData data];
    char buffer[512];
    for (;;) {
        ssize_t count = read(readFD, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        if (output.length < 2048) [output appendBytes:buffer length:MIN((NSUInteger)count, 2048 - output.length)];
    }
    close(readFD);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    NSString *summary = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    summary = [summary stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    @synchronized (BBState) {
        if (BBState.generation != generation || BBState.child != child) return;
        BOOL stopped = BBState.stopping;
        BBState.child = 0;
        BBState.stopping = NO;
        BBState.phase = stopped ? @"stopped" :
            (waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? @"done" : @"error");
        BBState.message = stopped ? @"任务已停止" :
            ([BBState.phase isEqualToString:@"done"] ? (summary.length ? summary : @"任务完成") : @"任务未完成，请在解锁后重试");
    }
}

static NSDictionary *BBStart(NSDictionary *request) {
    NSString *task = request[@"task"];
    NSString *model = request[@"model"] ?: @"mock";
    if (![task isKindOfClass:NSString.class] || ![model isKindOfClass:NSString.class] || task.length > 80)
        return @{@"ok": @NO, @"error": @"无效的文字任务"};
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *speechPunctuation = [NSCharacterSet characterSetWithCharactersInString:@"。.!！？?，,"];
    while (task.length && [speechPunctuation characterIsMember:[task characterAtIndex:task.length - 1]])
        task = [[task substringToIndex:task.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *app = BBAllowedTarget(task);
    if (!app || ![@[@"mock", @"claude"] containsObject:model])
        return @{@"ok": @NO, @"error": @"首版只接受打开设置、备忘录、地图或在地图搜索地点"};
    BOOL mapSearch = [task hasPrefix:@"在地图搜索"];
    if (mapSearch && ![model isEqualToString:@"claude"])
        return @{@"ok": @NO, @"error": @"地图搜索请使用 Claude 模型"};
    @synchronized (BBState) {
        if (BBState.child > 0) return @{@"ok": @NO, @"error": @"已有任务正在执行"};
        int outputPipe[2];
        if (pipe(outputPipe)) return @{@"ok": @NO, @"error": @"无法创建任务管道"};
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        char executable[PATH_MAX] = {0};
        uint32_t executableSize = sizeof(executable);
        if (_NSGetExecutablePath(executable, &executableSize)) {
            posix_spawn_file_actions_destroy(&actions); close(outputPipe[0]); close(outputPipe[1]);
            return @{@"ok": @NO, @"error": @"无法定位任务程序"};
        }
        const char *argvClaude[] = {executable, "--claude", mapSearch ? "--auto-map" : NULL,
                                    task.UTF8String, NULL};
        const char *argvClaudeOpen[] = {executable, "--claude", task.UTF8String, NULL};
        const char *argvMock[] = {executable, task.UTF8String, NULL};
        pid_t child = 0;
        int spawnResult = posix_spawn(&child, executable, &actions, NULL,
                                     (char *const *)([model isEqualToString:@"claude"] ?
                                                     (mapSearch ? argvClaude : argvClaudeOpen) : argvMock), environ);
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[1]);
        if (spawnResult) { close(outputPipe[0]); return @{@"ok": @NO,
            @"error": [NSString stringWithFormat:@"无法启动任务进程（%d）", spawnResult]}; }
        int readFD = outputPipe[0];
        BBState.generation++;
        NSUInteger generation = BBState.generation;
        BBState.child = child;
        BBState.stopping = NO;
        BBState.phase = @"running";
        BBState.message = @"正在执行";
        BBState.app = app;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBWaitForChild(child, readFD, generation);
        });
        return BBStatus();
    }
}

static NSDictionary *BBStop(void) {
    @synchronized (BBState) {
        if (BBState.child <= 0) return BBStatus();
        BBState.stopping = YES;
        BBState.phase = @"stopping";
        BBState.message = @"正在停止";
        kill(BBState.child, SIGTERM);
        return BBStatus();
    }
}

static NSDictionary *BBHandle(NSDictionary *request) {
    NSString *op = request[@"op"];
    if ([op isEqualToString:@"status"]) return BBStatus();
    if ([op isEqualToString:@"start"]) return BBStart(request);
    if ([op isEqualToString:@"stop"]) return BBStop();
    return @{@"ok": @NO, @"error": @"未知操作"};
}

static void BBClient(int fd) {
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (getpeereid(fd, &uid, &gid) || uid != 501) return;
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSMutableData *data = [NSMutableData data];
    char byte = 0;
    while (data.length < 4096 && read(fd, &byte, 1) == 1 && byte != '\n') [data appendBytes:&byte length:1];
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *reply = [request isKindOfClass:NSDictionary.class] ? BBHandle(request) :
        @{@"ok": @NO, @"error": @"无效请求"};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if (encoded) {
        NSMutableData *line = [encoded mutableCopy];
        [line appendBytes:"\n" length:1];
        const uint8_t *cursor = line.bytes;
        NSUInteger remaining = line.length;
        while (remaining) {
            ssize_t written = write(fd, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) break;
            cursor += written; remaining -= (NSUInteger)written;
        }
    }
}

int BBServe(void) {
    @autoreleasepool {
        if (getuid() != 501) { fputs("beanbaod --serve must run as mobile\n", stderr); return 1; }
        BBState = [BBServiceState new];
        BBState.phase = @"idle";
        BBState.message = @"等待任务";
        signal(SIGPIPE, SIG_IGN);
        umask(077);
        struct stat existing = {0};
        if (!lstat(BBServiceSocket, &existing)) {
            if (!S_ISSOCK(existing.st_mode) || existing.st_uid != 501 || unlink(BBServiceSocket)) return 1;
        } else if (errno != ENOENT) return 1;
        int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listener < 0) return 1;
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, BBServiceSocket, sizeof(address.sun_path));
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(BBServiceSocket, 0600) ||
            listen(listener, 4)) { close(listener); return 1; }
        for (;;) {
            int client = accept(listener, NULL, NULL);
            if (client < 0) { if (errno == EINTR) continue; break; }
            @autoreleasepool { BBClient(client); close(client); }
        }
        close(listener);
        unlink(BBServiceSocket);
        return 1;
    }
}
