#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const char *BBSocket = "/var/mobile/Library/Caches/BeanBao/bridge.sock";
static const char *BBToken = "/var/mobile/Library/Caches/BeanBao/bridge.token";
static const char *BBClaudeKey = "/var/mobile/Library/Caches/BeanBao/claude.key";
static NSString *const BBClaudeModel = @"claude-sonnet-5-5";
extern int BBServe(void);

static NSDictionary *BBError(NSString *message) { return @{@"ok": @NO, @"error": message ?: @"Unknown error"}; }
static BOOL BBWriteAll(int fd, NSData *data) {
    const uint8_t *cursor = data.bytes;
    NSUInteger left = data.length;
    while (left) {
        ssize_t count = write(fd, cursor, left);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        cursor += count; left -= (NSUInteger)count;
    }
    return YES;
}

static NSString *BBReadSecret(const char *path, NSUInteger expectedLength) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != 501 ||
        (info.st_mode & 077) || info.st_size <= 0 || info.st_size > 4096) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData data];
    uint8_t chunk[512];
    while (data.length <= 4096) {
        ssize_t count = read(fd, chunk, sizeof(chunk));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { close(fd); return nil; }
        if (!count) break;
        [data appendBytes:chunk length:(NSUInteger)count];
    }
    close(fd);
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value || (expectedLength && value.length != expectedLength)) return nil;
    return value;
}

static NSDictionary *BBBridge(NSDictionary *request) {
    NSString *token = BBReadSecret(BBToken, 64);
    if (!token) return BBError(@"Bridge token unavailable");
    NSMutableDictionary *payload = [request mutableCopy];
    payload[@"token"] = token;
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json || json.length >= 65536) return BBError(@"Invalid bridge request");
    NSMutableData *line = [json mutableCopy]; [line appendBytes:"\n" length:1];
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return BBError(@"Socket failed");
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, BBSocket, sizeof(address.sun_path));
    struct timeval timeout = {.tv_sec = 15};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address))) { close(fd); return BBError(@"Bridge unavailable"); }
    if (!BBWriteAll(fd, line)) { close(fd); return BBError(@"Bridge write failed"); }
    NSMutableData *response = [NSMutableData data];
    uint8_t chunk[4096];
    BOOL foundNewline = NO;
    while (response.length < 8 * 1024 * 1024 && !foundNewline) {
        ssize_t count = read(fd, chunk, sizeof(chunk));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        const uint8_t *end = memchr(chunk, '\n', (size_t)count);
        [response appendBytes:chunk length:end ? (NSUInteger)(end - chunk) : (NSUInteger)count];
        foundNewline = end != NULL;
    }
    close(fd);
    NSDictionary *result = [NSJSONSerialization JSONObjectWithData:response options:0 error:nil];
    return [result isKindOfClass:NSDictionary.class] ? result : BBError(@"Invalid bridge response");
}

static BOOL BBHasSecret(id value) {
    static NSArray<NSRegularExpression *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *sources = @[@"\\bsk-[A-Za-z0-9_-]{16,}\\b", @"\\bAKIA[0-9A-Z]{16}\\b",
                             @"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
                             @"\\b(?:api[_ -]?key|bearer token)\\s*[:=]\\s*\\S{12,}"];
        NSMutableArray *compiled = [NSMutableArray array];
        for (NSString *source in sources) {
            NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:source
                                                                                       options:NSRegularExpressionCaseInsensitive error:nil];
            if (expression) [compiled addObject:expression];
        }
        patterns = [compiled copy];
    });
    if ([value isKindOfClass:NSString.class]) {
        for (NSRegularExpression *pattern in patterns)
            if ([pattern firstMatchInString:value options:0 range:NSMakeRange(0, [value length])]) return YES;
    } else if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) if (BBHasSecret(item)) return YES;
    } else if ([value isKindOfClass:NSDictionary.class]) {
        for (id item in [value allValues]) if (BBHasSecret(item)) return YES;
    }
    return NO;
}

static NSDictionary *BBClaudeAction(NSString *task, NSDictionary *observation, NSArray *history, NSString *key) {
    NSMutableDictionary *state = [observation mutableCopy];
    NSDictionary *screenshot = state[@"screenshot"];
    [state removeObjectForKey:@"screenshot"];
    NSDictionary *prompt = @{@"task": task, @"observation": state,
                             @"recent_actions": history.count > 4 ? [history subarrayWithRange:NSMakeRange(history.count - 4, 4)] : history};
    NSData *promptJSON = [NSJSONSerialization dataWithJSONObject:prompt options:0 error:nil];
    if (!promptJSON) return BBError(@"Cannot encode model prompt");
    NSMutableArray *content = [NSMutableArray arrayWithObject:@{@"type": @"text",
        @"text": [[NSString alloc] initWithData:promptJSON encoding:NSUTF8StringEncoding]}];
    if ([screenshot[@"data"] isKindOfClass:NSString.class]) [content addObject:@{
        @"type": @"image", @"source": @{@"type": @"base64", @"media_type": @"image/jpeg", @"data": screenshot[@"data"]}}];
    NSDictionary *schema = @{@"type": @"object", @"properties": @{
        @"action": @{@"type": @"string", @"enum": @[@"launch_app", @"tap", @"swipe", @"input_text", @"press_key", @"done"]},
        @"bundle_id": @{@"type": @"string"}, @"x": @{@"type": @"number"}, @"y": @{@"type": @"number"},
        @"x1": @{@"type": @"number"}, @"y1": @{@"type": @"number"},
        @"x2": @{@"type": @"number"}, @"y2": @{@"type": @"number"},
        @"text": @{@"type": @"string"}, @"key": @{@"type": @"string"}, @"summary": @{@"type": @"string"}},
        @"required": @[@"action"], @"additionalProperties": @NO};
    NSDictionary *body = @{@"model": BBClaudeModel, @"max_tokens": @4096,
        @"system": @"Return one JSON action: launch_app, tap, swipe, input_text, press_key or done. Use screen point coordinates. For a Maps search, open Maps, tap its search field, input the exact requested place, press enter, then return done after results appear; never start navigation. Never install, run shell, read files, purchase, send messages, delete, or act on locked screen. If uncertain, return done with a short reason.",
        @"output_config": @{@"effort": @"low", @"format": @{@"type": @"json_schema", @"schema": schema}},
        @"messages": @[@{@"role": @"user", @"content": content}]};
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!bodyData) return BBError(@"Cannot encode model request");
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://api.anthropic.com/v1/messages"]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = bodyData;
    request.timeoutInterval = 30;
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSData *replyData = nil;
    __block NSHTTPURLResponse *http = nil;
    __block NSError *networkError = nil;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        replyData = data; http = (NSHTTPURLResponse *)response; networkError = error;
        dispatch_semaphore_signal(semaphore);
    }] resume];
    long waited = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 35 * NSEC_PER_SEC));
    [session finishTasksAndInvalidate];
    if (waited || networkError || http.statusCode != 200 || !replyData) return BBError(@"Claude request failed");
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:replyData options:0 error:nil];
    if (![reply isKindOfClass:NSDictionary.class] ||
        [@[@"max_tokens", @"refusal"] containsObject:reply[@"stop_reason"]]) return BBError(@"Claude returned no complete action");
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *part in reply[@"content"])
        if ([part[@"type"] isEqualToString:@"text"] && [part[@"text"] isKindOfClass:NSString.class]) [text appendString:part[@"text"]];
    NSDictionary *action = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [action isKindOfClass:NSDictionary.class] ? action : BBError(@"Claude returned invalid action JSON");
}

static NSDictionary *BBMockAction(NSString *task, NSDictionary *observation, NSUInteger steps) {
    NSDictionary *targets = @{@"设置": @"com.apple.Preferences", @"备忘录": @"com.apple.mobilenotes", @"地图": @"com.apple.Maps"};
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *name in targets) if ([task containsString:name]) [matches addObject:targets[name]];
    if (matches.count != 1 || ![task hasPrefix:@"打开"]) return BBError(@"Mock model only supports explicit open-app tasks");
    NSString *target = matches[0];
    if ([observation[@"frontmost_app"][@"bundleId"] isEqualToString:target]) return @{@"action": @"done", @"summary": @"目标 App 已在前台"};
    if (steps) return BBError(@"App launch did not reach target");
    return @{@"action": @"launch_app", @"bundle_id": target};
}

static NSString *BBRequestedApp(NSString *task) {
    if ([task hasPrefix:@"在地图搜索"]) return @"com.apple.Maps";
    NSDictionary *targets = @{@"设置": @"com.apple.Preferences", @"备忘录": @"com.apple.mobilenotes", @"地图": @"com.apple.Maps"};
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *name in targets) if ([task containsString:name]) [matches addObject:targets[name]];
    return matches.count == 1 ? matches[0] : nil;
}

static NSString *BBMapQuery(NSString *task) {
    if (![task hasPrefix:@"在地图搜索"] || task.length <= 5 || task.length > 55) return nil;
    NSString *query = [task substringFromIndex:5];
    return [query rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound ? query : nil;
}

static BOOL BBSearchFieldContainsPoint(NSDictionary *observation, double x, double y) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return NO;
    for (id item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        if (![label isKindOfClass:NSString.class] || label.length > 60 ||
            !([label containsString:@"搜索"] || [[label lowercaseString] containsString:@"search"])) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (width >= 20 && height >= 20 && x >= left && x < left + width &&
            y >= top && y < top + height) return YES;
    }
    return NO;
}

static BOOL BBValidAction(NSDictionary *action, NSDictionary *observation, NSString *task,
                          NSArray *history, BOOL allowUI, BOOL autoMap) {
    NSString *name = action[@"action"];
    if (![@[@"launch_app", @"tap", @"swipe", @"input_text", @"press_key", @"done"] containsObject:name]) return NO;
    NSDictionary *state = observation[@"device_state"];
    if (![state[@"locked_known"] boolValue] || [state[@"locked"] boolValue] ||
        ![state[@"screen_on_known"] boolValue] || ![state[@"screen_on"] boolValue]) return NO;
    NSString *requested = BBRequestedApp(task);
    NSString *foreground = observation[@"frontmost_app"][@"bundleId"];
    if (autoMap) {
        NSString *query = BBMapQuery(task);
        if (!query) return NO;
        NSUInteger uiSteps = 0;
        for (NSDictionary *item in history)
            if (![@"launch_app" isEqualToString:item[@"action"]]) uiSteps++;
        if ([name isEqualToString:@"done"])
            return [foreground isEqualToString:@"com.apple.Maps"] && uiSteps == 3 &&
                ([observation[@"ui"] isKindOfClass:NSDictionary.class] ||
                 [observation[@"ocr"] isKindOfClass:NSDictionary.class]);
        if ([name isEqualToString:@"launch_app"])
            return history.count == 0 && [action[@"bundle_id"] isEqualToString:@"com.apple.Maps"];
        if (!allowUI || ![foreground isEqualToString:@"com.apple.Maps"]) return NO;
        if ([name isEqualToString:@"tap"] && uiSteps == 0) {
            id x = action[@"x"], y = action[@"y"];
            return [x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
                isfinite([x doubleValue]) && isfinite([y doubleValue]) &&
                BBSearchFieldContainsPoint(observation, [x doubleValue], [y doubleValue]);
        }
        if ([name isEqualToString:@"input_text"] && uiSteps == 1)
            return [action[@"text"] isKindOfClass:NSString.class] && [action[@"text"] isEqualToString:query];
        if ([name isEqualToString:@"press_key"] && uiSteps == 2)
            return [action[@"key"] isKindOfClass:NSString.class] && [action[@"key"] isEqualToString:@"enter"];
        return NO;
    }
    if ([name isEqualToString:@"done"]) return requested && [foreground isEqualToString:requested];
    if ([name isEqualToString:@"launch_app"])
        return requested && [action[@"bundle_id"] isEqualToString:requested];
    if (!allowUI || !requested || ![foreground isEqualToString:requested]) return NO;
    if ([name isEqualToString:@"tap"] || [name isEqualToString:@"swipe"]) {
        NSArray *pairs = [name isEqualToString:@"tap"] ? @[@[@"x", @"y"]] : @[@[@"x1", @"y1"], @[@"x2", @"y2"]];
        double width = [observation[@"screen"][@"width"] doubleValue];
        double height = [observation[@"screen"][@"height"] doubleValue];
        for (NSArray *pair in pairs) {
            id x = action[pair[0]], y = action[pair[1]];
            if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
                !isfinite([x doubleValue]) || !isfinite([y doubleValue]) ||
                [x doubleValue] < 0 || [x doubleValue] >= width || [y doubleValue] < 0 || [y doubleValue] >= height) return NO;
        }
    }
    if ([name isEqualToString:@"input_text"] &&
        (![action[@"text"] isKindOfClass:NSString.class] || [action[@"text"] length] < 1 || [action[@"text"] length] > 200)) return NO;
    if ([name isEqualToString:@"press_key"] && ![@[@"enter", @"delete", @"backspace", @"space"] containsObject:action[@"key"]]) return NO;
    return YES;
}

static BOOL BBApprove(NSDictionary *action) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:action options:0 error:nil];
    fprintf(stdout, "待执行：%s\n输入 yes 执行这一步：", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
    char answer[16] = {0};
    return fgets(answer, sizeof(answer), stdin) && !strncmp(answer, "yes", 3);
}

static int BBRun(NSString *task, BOOL claude, BOOL allowUI, BOOL autoMap) {
    NSString *key = claude ? BBReadSecret(BBClaudeKey, 0) : nil;
    if (claude && (![key hasPrefix:@"sk-ant-"] || key.length < 24)) { fprintf(stderr, "Claude Key 未配置或权限不安全\n"); return 1; }
    NSMutableArray *history = [NSMutableArray array];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    for (int step = 0; step < 20 && [deadline timeIntervalSinceNow] > 0; step++) {
        NSDictionary *observation = BBBridge(@{@"op": @"observe", @"ui": @YES,
            @"ocr": @(claude), @"screenshot": @(claude)});
        if (![observation[@"ok"] boolValue]) { fprintf(stderr, "观察失败\n"); return 1; }
        if (claude && (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"]))) {
            fprintf(stderr, "界面包含疑似密钥，已停止模型请求\n"); return 1;
        }
        NSDictionary *action = claude ? BBClaudeAction(task, observation, history, key) : BBMockAction(task, observation, history.count);
        if (action[@"error"] || !BBValidAction(action, observation, task, history, allowUI, autoMap)) { fprintf(stderr, "模型动作被拒绝\n"); return 1; }
        NSString *name = action[@"action"];
        if ([name isEqualToString:@"done"]) { puts([action[@"summary"] isKindOfClass:NSString.class] ? [action[@"summary"] UTF8String] : "完成"); return 0; }
        if (![name isEqualToString:@"launch_app"] && !autoMap && !BBApprove(action)) { fprintf(stderr, "用户未批准动作\n"); return 1; }
        NSDictionary *fresh = BBBridge(@{@"op": @"observe", @"ui": @YES});
        if (![fresh[@"ok"] boolValue] || ![fresh[@"ui"] isEqual:observation[@"ui"]] ||
            ![fresh[@"frontmost_app"][@"bundleId"] isEqual:observation[@"frontmost_app"][@"bundleId"]] ||
            !BBValidAction(action, fresh, task, history, allowUI, autoMap) ||
            [NSDate.date timeIntervalSince1970] - [fresh[@"timestamp"] doubleValue] > 8) {
            fprintf(stderr, "界面已变化或观察失效，停止\n"); return 1;
        }
        NSMutableDictionary *request = [action mutableCopy];
        request[@"op"] = @"act"; request[@"observation_id"] = fresh[@"observation_id"];
        NSDictionary *result = BBBridge(request);
        if (![result[@"ok"] boolValue]) { fprintf(stderr, "动作执行失败\n"); return 1; }
        [history addObject:action];
    }
    fprintf(stderr, "任务超过时间或步数上限\n"); return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--serve")) return BBServe();
        if (argc < 2) { fprintf(stderr, "用法：beanbaod [--claude] [--approve-ui] '任务文字'\n"); return 2; }
        BOOL claude = NO, allowUI = NO, autoMap = NO;
        NSString *task = nil;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--claude"]) claude = YES;
            else if ([arg isEqualToString:@"--approve-ui"]) allowUI = YES;
            else if ([arg isEqualToString:@"--auto-map"]) { autoMap = YES; allowUI = YES; }
            else if (!task) task = arg;
            else { fprintf(stderr, "参数过多\n"); return 2; }
        }
        if (!task.length) { fprintf(stderr, "缺少任务\n"); return 2; }
        if (autoMap && (!claude || !BBMapQuery(task))) return 2;
        return BBRun(task, claude, allowUI, autoMap);
    }
}
