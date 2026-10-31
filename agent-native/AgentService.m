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
#import "BBAudit.h"

extern char **environ;
extern void BBReleaseWakeLease(void);

static const char *BBServiceSocket = "/var/mobile/Library/Caches/BeanBao/agent.sock";

@interface BBServiceState : NSObject
@property(nonatomic) pid_t child;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *app;
@property(nonatomic, copy) NSString *serviceID;
@property(nonatomic, copy) NSString *taskID;
@property(nonatomic) BOOL stopping;
@end
@implementation BBServiceState
@end

static BBServiceState *BBState;

static BOOL BBIsNoteTask(NSString *task) {
    return [task hasPrefix:@"新建备忘录："] && task.length >= 10 && task.length <= 166 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
}

static NSString *BBCompletionMessage(NSString *task) {
    if ([task hasPrefix:@"在地图搜索"]) return @"地图搜索已完成";
    if (BBIsNoteTask(task)) return @"备忘录已创建";
    return @"目标 App 已在前台";
}

static NSString *BBNormalizeTask(NSString *task) {
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *speechPunctuation = [NSCharacterSet characterSetWithCharactersInString:@"。.!！？?，,"];
    while (![task hasPrefix:@"新建备忘录："] && task.length &&
           [speechPunctuation characterIsMember:[task characterAtIndex:task.length - 1]])
        task = [[task substringToIndex:task.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return task;
}

static NSString *BBAllowedTarget(NSString *task) {
    if ([task isEqualToString:@"打开设置"]) return @"设置";
    if ([task isEqualToString:@"打开备忘录"]) return @"备忘录";
    if ([task isEqualToString:@"打开地图"]) return @"地图";
    if ([task isEqualToString:@"打开通讯录"]) return @"通讯录";
    if ([task hasPrefix:@"在地图搜索"] && task.length > 5 && task.length <= 55 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        return @"地图";
    if (BBIsNoteTask(task)) return @"备忘录";
    return nil;
}

static BOOL BBTaskModelAllowed(NSString *task, NSString *model) {
    if ([task isEqualToString:@"打开通讯录"]) return [model isEqualToString:@"mock"];
    return ![task hasPrefix:@"在地图搜索"] || [model isEqualToString:@"claude"];
}

static BOOL BBUsesTextHarness(NSString *task) {
    return [@[@"打开设置", @"打开备忘录", @"打开地图", @"打开通讯录"] containsObject:task];
}

static NSDictionary *BBStatus(void) {
    @synchronized (BBState) {
        return @{@"ok": @YES, @"phase": BBState.phase ?: @"idle",
                 @"message": BBState.message ?: @"",
                 @"app": BBState.app ?: @"", @"running": @(BBState.child > 0),
                 @"service_id": BBState.serviceID ?: @"",
                 @"task_id": BBState.taskID ?: @""};
    }
}

static NSString *BBFailureMessage(NSString *output) {
    if ([output containsString:@"设备已锁定或屏幕关闭"])
        return @"设备已锁定或屏幕关闭，请解锁后重试";
    if ([output containsString:@"Claude Key 未配置"])
        return @"Claude Key 未配置或权限不安全";
    if ([output containsString:@"防自动锁屏不可用"])
        return @"防自动锁屏不可用，已停止任务";
    if ([output containsString:@"疑似密钥"])
        return @"界面或任务疑似包含敏感信息，已停止";
    if ([output containsString:@"模型请求或输出失败"])
        return @"模型请求或输出失败，请稍后重试";
    if ([output containsString:@"模型动作被策略拒绝"])
        return @"界面操作未通过安全校验，已停止";
    if ([output containsString:@"界面复核未通过"])
        return @"界面发生变化，已停止任务";
    if ([output containsString:@"备忘录界面状态不符合安全条件"])
        return @"备忘录界面状态不符合安全条件，已停止";
    if ([output containsString:@"任务超过时间或步数上限"])
        return @"任务超过时间或步数上限";
    return @"任务未完成，请检查界面后重试";
}

static void BBWaitForChild(pid_t child, int readFD, NSUInteger generation,
                           NSString *completionMessage, NSString *app) {
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
    // SIGTERM does not execute the child's @finally. Release before another
    // task can start; the bridge lease also expires if this service dies.
    BBReleaseWakeLease();
    NSString *summary = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    summary = [summary stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *auditAction = nil, *auditResult = nil;
    @synchronized (BBState) {
        if (BBState.generation != generation || BBState.child != child) return;
        BOOL stopped = BBState.stopping;
        BBState.child = 0;
        BBState.stopping = NO;
        BBState.phase = stopped ? @"stopped" :
            (waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? @"done" : @"error");
        BBState.message = stopped ? @"任务已停止" :
            ([BBState.phase isEqualToString:@"done"] ? completionMessage : BBFailureMessage(summary));
        auditAction = BBState.phase;
        auditResult = [auditAction isEqualToString:@"done"] ? @"ok" : @"failed";
    }
    BBAudit(@"task", app, auditAction, auditResult);
}

static NSDictionary *BBStart(NSDictionary *request) {
    NSString *task = request[@"task"];
    NSString *model = request[@"model"] ?: @"mock";
    if (![task isKindOfClass:NSString.class] || ![model isKindOfClass:NSString.class] || task.length > 220)
        return @{@"ok": @NO, @"error": @"无效的文字任务"};
    task = BBNormalizeTask(task);
    NSString *app = BBAllowedTarget(task);
    if (!app || ![@[@"mock", @"claude"] containsObject:model])
        return @{@"ok": @NO, @"error": @"首版只接受打开指定 App、地图搜索或新建备忘录"};
    BOOL mapSearch = [task hasPrefix:@"在地图搜索"];
    BOOL noteTask = BBIsNoteTask(task);
    NSString *completionMessage = BBCompletionMessage(task);
    if (!BBTaskModelAllowed(task, model))
        return @{@"ok": @NO, @"error": [task isEqualToString:@"打开通讯录"] ?
            @"打开通讯录请使用模拟模型" : @"地图搜索请使用 Claude 模型"};
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
        const char *argvClaude[] = {executable, "--claude", mapSearch ? "--auto-map" : "--auto-note",
                                    task.UTF8String, NULL};
        const char *argvNote[] = {executable, "--auto-note", task.UTF8String, NULL};
        const char *argvMock[] = {executable, "--harness-mock", task.UTF8String, NULL};
        pid_t child = 0;
        int spawnResult = posix_spawn(&child, executable, &actions, NULL,
                                     (char *const *)(noteTask ? argvNote :
                                         (BBUsesTextHarness(task) ? argvMock : argvClaude)), environ);
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[1]);
        if (spawnResult) { close(outputPipe[0]); return @{@"ok": @NO,
            @"error": [NSString stringWithFormat:@"无法启动任务进程（%d）", spawnResult]}; }
        int readFD = outputPipe[0];
        BBState.generation++;
        NSUInteger generation = BBState.generation;
        BBState.taskID = NSUUID.UUID.UUIDString;
        BBState.child = child;
        BBState.stopping = NO;
        BBState.phase = @"running";
        BBState.message = @"正在执行";
        BBState.app = app;
        BBAudit(@"task", app, @"start", @"accepted");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBWaitForChild(child, readFD, generation, completionMessage, app);
        });
        return BBStatus();
    }
}

static NSDictionary *BBStop(NSDictionary *request) {
    @synchronized (BBState) {
        NSString *requestedTask = request[@"task_id"];
        NSString *requestedService = request[@"service_id"];
        if (requestedService && (![requestedService isKindOfClass:NSString.class] ||
                                 ![requestedService isEqualToString:BBState.serviceID ?: @""]))
            return @{@"ok": @NO, @"error": @"服务已变化，未停止其他任务"};
        if (requestedTask && (![requestedTask isKindOfClass:NSString.class] ||
                              ![requestedTask isEqualToString:BBState.taskID ?: @""]))
            return @{@"ok": @NO, @"error": @"任务已变化，未停止其他任务"};
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
    if ([op isEqualToString:@"stop"]) return BBStop(request);
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
        BBState.serviceID = NSUUID.UUID.UUIDString;
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
