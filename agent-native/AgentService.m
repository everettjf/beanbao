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
#import "ModelConfig.h"

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
    if ([task hasPrefix:@"在地图搜索"]) return @"Maps search completed";
    if (BBIsNoteTask(task)) return @"Note created";
    return @"Target app is in the foreground";
}

static NSString *BBNormalizeTask(NSString *task) {
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lower = task.lowercaseString;
    if ([lower hasPrefix:@"please "])
        task = [[task substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *prefix in @[@"请帮我", @"帮我", @"请"]) {
        if ([task hasPrefix:prefix]) {
            task = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    NSCharacterSet *speechPunctuation = [NSCharacterSet characterSetWithCharactersInString:@"。.!！？?，,"];
    lower = task.lowercaseString;
    BOOL noteTask = [task hasPrefix:@"新建备忘录："] ||
        [lower hasPrefix:@"create note:"] || [lower hasPrefix:@"create a note:"];
    while (!noteTask && task.length &&
           [speechPunctuation characterIsMember:[task characterAtIndex:task.length - 1]])
        task = [[task substringToIndex:task.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([task hasPrefix:@"打开一下"]) {
        NSString *name = [task substringFromIndex:@"打开一下".length];
        if ([@[@"设置", @"备忘录", @"地图", @"通讯录"] containsObject:name])
            task = [@"打开" stringByAppendingString:name];
    }
    for (NSString *prefix in @[@"在地图里搜索", @"在地图上搜索"]) {
        if ([task hasPrefix:prefix]) {
            task = [@"在地图搜索" stringByAppendingString:
                [task substringFromIndex:prefix.length]];
            break;
        }
    }
    lower = task.lowercaseString;
    NSDictionary *englishOpen = @{@"open settings": @"打开设置", @"open maps": @"打开地图",
        @"open contacts": @"打开通讯录", @"open notes": @"打开备忘录",
        @"open the settings": @"打开设置", @"open the maps": @"打开地图",
        @"open the contacts": @"打开通讯录", @"open the notes": @"打开备忘录"};
    if (englishOpen[lower]) return englishOpen[lower];
    for (NSString *prefix in @[@"search maps for ", @"find in maps "]) {
        if ([lower hasPrefix:prefix]) {
            NSString *place = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [@"在地图搜索" stringByAppendingString:place];
        }
    }
    for (NSString *prefix in @[@"create note:", @"create a note:"]) {
        if ([lower hasPrefix:prefix]) {
            NSString *content = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [@"新建备忘录：" stringByAppendingString:content];
        }
    }
    return task;
}

NSString *BBAllowedTarget(NSString *task) {
    if ([task isEqualToString:@"打开设置"]) return @"Settings";
    if ([task isEqualToString:@"打开备忘录"]) return @"Notes";
    if ([task isEqualToString:@"打开地图"]) return @"Maps";
    if ([task isEqualToString:@"打开通讯录"]) return @"Contacts";
    if ([task hasPrefix:@"在地图搜索"] && task.length > 5 && task.length <= 55 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        return @"Maps";
    if (BBIsNoteTask(task)) return @"Notes";
    return nil;
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
    if ([output containsString:@"Unsupported request"])
        return @"I could not identify one supported action. Try a clearer request.";
    if ([output containsString:@"Model settings changed"])
        return @"Model settings changed. Submit the task again.";
    if ([output containsString:@"Device is locked or screen is off"])
        return @"Unlock the phone and try again";
    if ([output containsString:@"Model key is not configured"])
        return @"Model key is missing or has unsafe permissions. Open Model settings.";
    if ([output containsString:@"Could not keep the screen awake"])
        return @"Could not keep the screen awake. Task stopped.";
    if ([output containsString:@"may contain sensitive information"] ||
        [output containsString:@"may contain a key"])
        return @"The screen or request may contain sensitive information. Task stopped.";
    if ([output containsString:@"Model request or response failed"])
        return @"Model request or response failed. Try again later.";
    if ([output containsString:@"Cannot safely use the current Maps screen"])
        return @"Cannot safely use the current Maps screen. Check it and try again.";
    if ([output containsString:@"Could not verify the requested place in Maps"])
        return @"Could not verify the requested place in Maps. Task stopped.";
    if ([output containsString:@"Model action was rejected by policy"])
        return @"The action failed the safety check. Task stopped.";
    if ([output containsString:@"Screen verification failed"])
        return @"The screen changed unexpectedly. Task stopped.";
    if ([output containsString:@"Notes screen is not safe to use"])
        return @"The Notes screen is not safe to use. Task stopped.";
    if ([output containsString:@"Task exceeded its time or step limit"])
        return @"Task exceeded its time or step limit";
    return @"Task incomplete. Check the screen and try again.";
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
    NSString *resolvedApp = nil;
    for (NSString *line in [summary componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"BB_INTENT="]) {
            NSString *candidate = [line substringFromIndex:@"BB_INTENT=".length];
            if ([@[@"Settings", @"Maps", @"Contacts", @"Notes", @"MapsSearch", @"NoteCreate"]
                    containsObject:candidate]) resolvedApp = candidate;
            break;
        }
    if (resolvedApp) {
        app = [resolvedApp isEqualToString:@"MapsSearch"] ? @"Maps" :
            ([resolvedApp isEqualToString:@"NoteCreate"] ? @"Notes" : resolvedApp);
        completionMessage = [resolvedApp isEqualToString:@"MapsSearch"] ? @"Maps search completed" :
            ([resolvedApp isEqualToString:@"NoteCreate"] ? @"Note created" : @"Target app is in the foreground");
    }
    NSString *auditAction = nil, *auditResult = nil;
    @synchronized (BBState) {
        if (BBState.generation != generation || BBState.child != child) return;
        BOOL stopped = BBState.stopping;
        BBState.child = 0;
        BBState.app = app;
        BBState.stopping = NO;
        BBState.phase = stopped ? @"stopped" :
            (waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? @"done" : @"error");
        BBState.message = stopped ? @"Task stopped" :
            ([BBState.phase isEqualToString:@"done"] ? completionMessage : BBFailureMessage(summary));
        auditAction = BBState.phase;
        auditResult = [auditAction isEqualToString:@"done"] ? @"ok" : @"failed";
    }
    BBAudit(@"task", app, auditAction, auditResult);
}

static NSDictionary *BBStart(NSDictionary *request) {
    NSString *task = request[@"task"];
    NSString *model = request[@"model"];
    if (![task isKindOfClass:NSString.class] ||
        (model && ![model isKindOfClass:NSString.class]) || task.length > 220)
        return @{@"ok": @NO, @"error": @"Invalid text request"};
    task = BBNormalizeTask(task);
    NSString *app = BBAllowedTarget(task);
    BOOL resolveTask = !app;
    if (resolveTask) app = @"BeanBao";
    NSString *selectedProvider = BBModelLoad()[@"provider"];
    if (model && ![model isEqualToString:selectedProvider])
        return @{@"ok": @NO, @"error": @"Model settings changed. Submit the task again."};
    BOOL noteTask = BBIsNoteTask(task);
    NSString *completionMessage = BBCompletionMessage(task);
    @synchronized (BBState) {
        if (BBState.child > 0) return @{@"ok": @NO, @"error": @"A task is already running"};
        int outputPipe[2];
        if (pipe(outputPipe)) return @{@"ok": @NO, @"error": @"Could not create the task pipe"};
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
            return @{@"ok": @NO, @"error": @"Could not locate the task executable"};
        }
        const char *argvMap[] = {executable, "--harness-map", task.UTF8String,
                                 selectedProvider.UTF8String, NULL};
        const char *argvNote[] = {executable, "--harness-note", task.UTF8String, NULL};
        const char *argvText[] = {executable, "--harness-text", task.UTF8String, NULL};
        const char *argvResolve[] = {executable, "--resolve-task", task.UTF8String,
                                     selectedProvider.UTF8String, NULL};
        pid_t child = 0;
        int spawnResult = posix_spawn(&child, executable, &actions, NULL,
                                     (char *const *)(resolveTask ? argvResolve :
                                         (noteTask ? argvNote :
                                          (BBUsesTextHarness(task) ? argvText : argvMap))), environ);
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[1]);
        if (spawnResult) { close(outputPipe[0]); return @{@"ok": @NO,
            @"error": [NSString stringWithFormat:@"Could not start the task process (%d)", spawnResult]}; }
        int readFD = outputPipe[0];
        BBState.generation++;
        NSUInteger generation = BBState.generation;
        BBState.taskID = NSUUID.UUID.UUIDString;
        BBState.child = child;
        BBState.stopping = NO;
        BBState.phase = @"running";
        BBState.message = @"Running";
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
            return @{@"ok": @NO, @"error": @"The service changed. No other task was stopped."};
        if (requestedTask && (![requestedTask isKindOfClass:NSString.class] ||
                              ![requestedTask isEqualToString:BBState.taskID ?: @""]))
            return @{@"ok": @NO, @"error": @"The task changed. No other task was stopped."};
        if (BBState.child <= 0) return BBStatus();
        BBState.stopping = YES;
        BBState.phase = @"stopping";
        BBState.message = @"Stopping";
        kill(BBState.child, SIGTERM);
        return BBStatus();
    }
}

static NSDictionary *BBHandle(NSDictionary *request) {
    NSString *op = request[@"op"];
    if ([op isEqualToString:@"status"]) return BBStatus();
    if ([op isEqualToString:@"start"]) return BBStart(request);
    if ([op isEqualToString:@"stop"]) return BBStop(request);
    return @{@"ok": @NO, @"error": @"Unknown operation"};
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
        @{@"ok": @NO, @"error": @"Invalid request"};
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
        BBState.message = @"Waiting for a task";
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
