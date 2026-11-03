#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <float.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import "BBAudit.h"
#import "ModelConfig.h"

static const char *BBSocket = "/var/mobile/Library/Caches/BeanBao/bridge.sock";
static const char *BBToken = "/var/mobile/Library/Caches/BeanBao/bridge.token";
static NSString *BBExpectedProvider;
extern int BBServe(void);

static NSDictionary *BBError(NSString *message) { return @{@"ok": @NO, @"error": message ?: @"Unknown error"}; }

@interface BBNoRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@end
@implementation BBNoRedirectDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
    completionHandler:(void (^)(NSURLRequest *))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    completionHandler(nil);
}
@end
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

// C ABI for the Swift harness. The bridge token and socket path stay in this
// process; the Swift runtime receives only the JSON result of each request.
char *BBBridgeRequestJSON(const char *requestJSON) {
    @autoreleasepool {
        if (!requestJSON) return NULL;
        NSData *input = [[NSString stringWithUTF8String:requestJSON] dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *request = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
        if (![request isKindOfClass:NSDictionary.class]) return NULL;
        NSDictionary *reply = BBBridge(request);
        NSData *output = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
        if (!output || output.length > 8 * 1024 * 1024) return NULL;
        char *copy = malloc(output.length + 1);
        if (!copy) return NULL;
        memcpy(copy, output.bytes, output.length);
        copy[output.length] = '\0';
        return copy;
    }
}

void BBBridgeFreeJSON(char *response) { free(response); }
extern int32_t BBRunHarnessText(const char *task);
extern int32_t BBRunHarnessNote(const char *task);
extern int32_t BBRunHarnessMap(const char *task);
extern int32_t BBRunHarnessResearch(const char *task, const char *workflowID);
extern int32_t BBRunHarnessAppStore(const char *task, const char *workflowID);
extern int32_t BBRunHarnessDeliveryPlan(const char *task, const char *workflowID);
extern NSString *BBAllowedTarget(NSString *task);
extern BOOL BBResearchPDFCandidate(NSString *task);
extern BOOL BBResearchBroadCandidate(NSString *task);
extern BOOL BBResearchAppCandidate(NSString *task);
static NSString *BBNoteText(NSString *task);
static NSString *BBMapQuery(NSString *task);

char *BBWorkflowClaudeConfigJSON(void) {
    @autoreleasepool {
        NSDictionary *config = BBModelLoad();
        if (![config[@"provider"] isEqualToString:@"claude"]) return NULL;
        NSString *model = BBModelProfile(config, @"claude")[@"model"];
        NSString *key = BBModelReadKey(@"claude");
        if (!model.length || !key.length) return NULL;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"model": model, @"key": key}
                                                           options:0 error:nil];
        if (!data || data.length > 8192) return NULL;
        char *copy = malloc(data.length + 1);
        if (!copy) return NULL;
        memcpy(copy, data.bytes, data.length);
        copy[data.length] = '\0';
        return copy;
    }
}

void BBReleaseWakeLease(void) {
    BBBridge(@{@"op": @"wake_lease", @"mode": @"release"});
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

static NSDictionary *BBClaudeAction(NSString *task, NSDictionary *observation, NSArray *history,
                                     NSString *model, NSString *key) {
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
    NSDictionary *body = @{@"model": model, @"max_tokens": @4096,
        @"system": @"Return one JSON action: launch_app, tap, swipe, input_text, press_key or done. Use screen point coordinates. For a Maps search, if the requested result is already visible return done. Otherwise open Maps; if an old place card covers search, tap its Close button first. Then tap the search field if needed and input the exact requested place only when the field is empty. If a search suggestion names the exact requested place (including a known localized name), tap that suggestion before using Enter. Return done only after the matching map pin and place card appear; never start navigation. For a new Note, open Notes, tap the new note button, input the exact requested content, tap Done, then return done only when the new content is visible. Never edit an existing note. Never install, run shell, read files, purchase, send messages, delete, or act on locked screen. If uncertain, return done with a short reason.",
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
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
        delegate:[BBNoRedirectDelegate new] delegateQueue:nil];
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

static NSDictionary *BBOpenAIChatRequestBody(NSString *task, NSDictionary *observation,
                                              NSArray *history, NSString *model, BOOL compatible) {
    NSMutableDictionary *state = [observation mutableCopy];
    NSDictionary *screenshot = state[@"screenshot"];
    [state removeObjectForKey:@"screenshot"];
    NSDictionary *prompt = @{@"task": task, @"observation": state,
        @"recent_actions": history.count > 4 ?
            [history subarrayWithRange:NSMakeRange(history.count - 4, 4)] : history};
    NSData *promptJSON = [NSJSONSerialization dataWithJSONObject:prompt options:0 error:nil];
    if (!promptJSON) return nil;
    NSMutableArray *content = [NSMutableArray arrayWithObject:@{@"type": @"text",
        @"text": [[NSString alloc] initWithData:promptJSON encoding:NSUTF8StringEncoding]}];
    if ([screenshot[@"data"] isKindOfClass:NSString.class])
        [content addObject:@{@"type": @"image_url", @"image_url": @{
            @"url": [@"data:image/jpeg;base64," stringByAppendingString:screenshot[@"data"]]}}];
    NSString *system = @"Return exactly one JSON object with an action: launch_app, tap, swipe, input_text, press_key or done. Use screen point coordinates. Search only the exact requested Maps place. If a matching pin and place card are visible, return done. Never start navigation, install apps, read files, pay, send messages, delete, edit existing notes or act on a locked screen. If uncertain, return {\"action\":\"done\",\"summary\":\"uncertain\"}. The device validates every action and rejects unsupported operations.";
    return @{@"model": model,
        compatible ? @"max_tokens" : @"max_completion_tokens": @2048,
        @"messages": @[@{@"role": @"system", @"content": system},
                         @{@"role": @"user", @"content": content}]};
}

static NSDictionary *BBParseOpenAIChatAction(NSData *data) {
    if (!data || data.length > 65536) return BBError(@"Model response too large");
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![reply isKindOfClass:NSDictionary.class]) return BBError(@"Invalid model response");
    NSArray *choices = reply[@"choices"];
    NSDictionary *choice = [choices isKindOfClass:NSArray.class] ? choices.firstObject : nil;
    if (![choice isKindOfClass:NSDictionary.class] ||
        ![choice[@"finish_reason"] isEqualToString:@"stop"])
        return BBError(@"Model did not finish one action");
    NSString *content = choice[@"message"][@"content"];
    if (![content isKindOfClass:NSString.class] || content.length > 8192)
        return BBError(@"Model action is missing");
    NSDictionary *action = [NSJSONSerialization JSONObjectWithData:
        [content dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [action isKindOfClass:NSDictionary.class] ? action : BBError(@"Invalid model action JSON");
}

static NSDictionary *BBOpenAIAction(NSString *task, NSDictionary *observation, NSArray *history,
                                    NSString *model, NSString *key, NSString *endpoint,
                                    BOOL compatible) {
    NSURLComponents *base = [NSURLComponents componentsWithString:endpoint];
    if (![base.scheme.lowercaseString isEqualToString:@"https"] || !base.host.length ||
        base.user || base.password || base.query || base.fragment)
        return BBError(@"Invalid model endpoint");
    NSString *path = [base.path stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"/"]];
    if (![path hasSuffix:@"chat/completions"])
        path = path.length ? [path stringByAppendingString:@"/chat/completions"] : @"chat/completions";
    base.path = [@"/" stringByAppendingString:path];
    NSDictionary *body = BBOpenAIChatRequestBody(task, observation, history, model, compatible);
    NSData *encoded = body ? [NSJSONSerialization dataWithJSONObject:body options:0 error:nil] : nil;
    if (!encoded) return BBError(@"Cannot encode model request");
    if (!base.URL) return BBError(@"Invalid model endpoint");
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:base.URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = encoded;
    request.timeoutInterval = 30;
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
        delegate:[BBNoRedirectDelegate new] delegateQueue:nil];
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
    if (waited || networkError || http.statusCode != 200) return BBError(@"Model request failed");
    return BBParseOpenAIChatAction(replyData);
}

static NSDictionary *BBModelAction(NSString *task, NSDictionary *observation, NSArray *history,
                                   NSDictionary *config, NSString *key) {
    NSString *provider = config[@"provider"];
    NSDictionary *profile = BBModelProfile(config, provider);
    NSString *model = profile[@"model"];
    if (!model.length || !key.length) return BBError(@"Model is not configured");
    if ([provider isEqualToString:@"claude"])
        return BBClaudeAction(task, observation, history, model, key);
    NSString *endpoint = [provider isEqualToString:@"openai"] ?
        @"https://api.openai.com/v1" : profile[@"endpoint"];
    return BBOpenAIAction(task, observation, history, model, key, endpoint,
                          [provider isEqualToString:@"compatible"]);
}

static BOOL BBHasUnsafeIntent(NSString *request) {
    NSString *lower = request.lowercaseString;
    if ([lower hasPrefix:@"不要"] || [lower hasPrefix:@"别"] ||
        [lower hasPrefix:@"删除"] || [lower hasPrefix:@"发消息"] ||
        [lower hasPrefix:@"付款"] || [lower hasPrefix:@"购买"] ||
        [lower hasPrefix:@"安装"] || [lower hasPrefix:@"拨打"] ||
        [lower hasPrefix:@"打电话"] || [lower hasPrefix:@"关闭"] ||
        [lower hasPrefix:@"开启"] || [lower hasPrefix:@"切换"]) return YES;
    for (NSString *join in @[@"并", @"并且", @"然后", @"再", @"同时"])
        for (NSString *verb in @[@"发消息", @"删除", @"付款", @"购买", @"安装", @"拨打", @"打电话", @"修改", @"编辑", @"关闭", @"开启", @"切换", @"打开"])
            if ([lower containsString:[join stringByAppendingString:verb]]) return YES;
    static NSRegularExpression *unsafe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unsafe = [NSRegularExpression regularExpressionWithPattern:
            @"^\\s*(?:do not|don't|never|send|message|call|delete|remove|pay|purchase|buy|install|change|edit|share|post|navigate|route|toggle|enable|disable|turn|set|update|rename)\\b|\\b(?:and|then|also)\\s+(?:send|message|call|delete|remove|pay|purchase|buy|install|change|edit|share|post|open|navigate|route|toggle|enable|disable|turn|set|update|rename)\\b"
            options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [unsafe firstMatchInString:request options:0 range:NSMakeRange(0, request.length)] != nil;
}

static BOOL BBIsCanonicalAppLookup(NSString *task) {
    if (![task isKindOfClass:NSString.class] || ![task hasPrefix:@"Find app "] ||
        task.length <= @"Find app ".length + 1 || task.length > 89 ||
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        return NO;
    NSString *lower = task.lowercaseString;
    return [lower rangeOfString:@" and "].location == NSNotFound &&
        [task rangeOfString:@"并"].location == NSNotFound;
}

static NSString *BBResolvedTask(NSString *request, NSDictionary *action) {
    if (![request isKindOfClass:NSString.class] || !request.length || request.length > 220 ||
        BBHasSecret(request) ||
        ![action[@"action"] isEqualToString:@"input_text"]) return nil;
    NSString *task = action[@"text"];
    if (![task isKindOfClass:NSString.class]) return nil;
    if ([task isEqualToString:@"Research PDF"] && BBResearchBroadCandidate(request))
        return task;
    if (BBHasUnsafeIntent(request)) return nil;
    if (BBIsCanonicalAppLookup(task)) {
        NSString *query = [task substringFromIndex:@"Find app ".length];
        if (![task hasPrefix:@"Find app "] || query.length < 2 || query.length > 80 ||
            [request rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound)
            return nil;
        return task;
    }
    if (!BBAllowedTarget(task)) return nil;
    NSString *query = BBMapQuery(task);
    if (query && [request rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound)
        return nil;
    NSString *note = BBNoteText(task);
    if (note && [request rangeOfString:note].location == NSNotFound) return nil;
    return task;
}

static int BBResolveAndRunTask(NSString *request, NSString *expectedProvider,
                               NSString *workflowID) {
    if (BBHasSecret(request)) { fputs("The request may contain a key. Model request stopped.\n", stderr); return 1; }
    if (BBHasUnsafeIntent(request) && !BBResearchBroadCandidate(request)) {
        fputs("Unsupported request\n", stderr); return 1;
    }
    NSDictionary *config = BBModelLoad();
    NSString *provider = config[@"provider"];
    NSString *key = BBModelReadKey(provider);
    if (![provider isEqualToString:expectedProvider]) { fputs("Model settings changed\n", stderr); return 1; }
    if (!key) { fputs("Model key is not configured\n", stderr); return 1; }
    NSDictionary *observation = @{@"device_state": @{@"locked_known": @YES, @"locked": @NO,
                                                    @"screen_on_known": @YES, @"screen_on": @YES},
                                  @"frontmost_app": @{@"bundleId": @"com.apple.springboard"},
                                  @"screen": @{@"width": @414, @"height": @896}};
    NSString *prompt = [NSString stringWithFormat:
        @"This is intent classification only; no UI or App Store action is being taken. Interpret the user utterance as one supported task. Repeated mentions of the same task are one request. A request to research a topic and make a sourced PDF, optionally with an addressed email draft and one App Store lookup or installation request, is one supported multi-step workflow; return input_text with text exactly Research PDF. The workflow will independently validate every requested output before execution. If the request is negated, ambiguous, or combines research with unrelated operations such as ordering, opening another app, or sending a message, return the done action with summary unsupported. Otherwise return the input_text action. Its text must be exactly one canonical task: Research PDF, 打开设置, 打开地图, 打开通讯录, 打开备忘录, 在地图搜索 followed by the exact requested place, 新建备忘录： followed by the exact requested note content, or Find app followed by the exact app name mentioned in the request. Find app only identifies a listing for review; it never installs anything. Use the shortest unambiguous app name from the request and do not invent or translate it. Preserve place and note text verbatim from the utterance. Do not include explanations in text. User utterance: %@", request];
    NSDictionary *action = BBModelAction(prompt, observation, @[], config, key);
    NSString *task = BBResolvedTask(request, action);
    if (!task) {
        fputs(action[@"error"] ? "Model request or response failed\n" : "Unsupported request\n", stderr);
        return 1;
    }
    if ([task isEqualToString:@"Research PDF"]) {
        if (![provider isEqualToString:@"claude"] ||
            ![[NSUUID alloc] initWithUUIDString:workflowID]) {
            fputs("Research PDF currently requires Claude\n", stderr);
            return 1;
        }
        fputs("BB_INTENT=ResearchPDF\n", stdout);
        fflush(stdout);
        return BBRunHarnessResearch(request.UTF8String, workflowID.UTF8String);
    }
    if (BBIsCanonicalAppLookup(task)) {
        if (![provider isEqualToString:@"claude"] || ![[NSUUID alloc] initWithUUIDString:workflowID]) {
            fputs("App Store lookup currently requires Claude\n", stderr);
            return 1;
        }
        fputs("BB_INTENT=AppStoreReview\n", stdout);
        fflush(stdout);
        return BBRunHarnessAppStore(request.UTF8String, workflowID.UTF8String);
    }
    NSString *app = BBMapQuery(task) ? @"MapsSearch" :
        (BBNoteText(task) ? @"NoteCreate" : BBAllowedTarget(task));
    printf("BB_INTENT=%s\n", app.UTF8String);
    fflush(stdout);
    if (BBNoteText(task)) return BBRunHarnessNote(task.UTF8String);
    if (BBMapQuery(task)) {
        BBExpectedProvider = expectedProvider;
        return BBRunHarnessMap(task.UTF8String);
    }
    return BBRunHarnessText(task.UTF8String);
}

static NSString *BBRequestedApp(NSString *task) {
    if ([task hasPrefix:@"在地图搜索"]) return @"com.apple.Maps";
    if ([task hasPrefix:@"新建备忘录："]) return @"com.apple.mobilenotes";
    NSDictionary *targets = @{@"设置": @"com.apple.Preferences", @"备忘录": @"com.apple.mobilenotes",
                              @"地图": @"com.apple.Maps", @"通讯录": @"com.apple.MobileAddressBook"};
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *name in targets) if ([task containsString:name]) [matches addObject:targets[name]];
    return matches.count == 1 ? matches[0] : nil;
}

static NSString *BBNoteText(NSString *task) {
    if (![task hasPrefix:@"新建备忘录："] || task.length < 10 || task.length > 166) return nil;
    NSString *content = [task substringFromIndex:6];
    return [content rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound ? content : nil;
}

static NSString *BBMapQuery(NSString *task) {
    if (![task hasPrefix:@"在地图搜索"] || task.length <= 5 || task.length > 55) return nil;
    NSString *query = [task substringFromIndex:5];
    return [query rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound ? query : nil;
}

static BOOL BBElementContainsPoint(NSDictionary *observation, double x, double y,
                                   NSArray<NSString *> *terms, BOOL excludeFolder) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return NO;
    for (id item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        if (![label isKindOfClass:NSString.class] || label.length > 60) continue;
        NSString *lower = label.lowercaseString;
        if (excludeFolder && ([lower containsString:@"文件夹"] || [lower containsString:@"folder"])) continue;
        BOOL matched = NO;
        for (NSString *term in terms) if ([lower containsString:term]) { matched = YES; break; }
        if (!matched) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (width >= 20 && height >= 20 && x >= left && x < left + width &&
            y >= top && y < top + height) return YES;
    }
    return NO;
}

static BOOL BBVisibleContains(NSDictionary *observation, NSString *needle) {
    for (NSString *part in @[@"ui", @"ocr"]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:observation[part] ?: @{} options:0 error:nil];
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if ([text containsString:needle]) return YES;
    }
    return NO;
}

static NSString *BBMapResultName(NSString *query) {
    NSDictionary<NSString *, NSString *> *knownMapNames = @{
        @"金门大桥": @"Golden Gate Bridge",
        @"渔人码头": @"Fisherman's Wharf",
        @"旧金山市政厅": @"San Francisco City Hall",
        @"加州科学院": @"California Academy of Sciences",
    };
    return knownMapNames[query] ?: query;
}

static BOOL BBMapResultVisible(NSDictionary *observation, NSString *query) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return NO;
    // Maps may replace a Chinese search with an English place card. Accept
    // a result only when both the map pin and the large place card name it;
    // a search-field value, OCR hit, or stale Directions button is insufficient.
    NSString *title = BBMapResultName(query);
    if (title.length < 5) return NO;
    BOOL pin = NO, card = NO;
    double screenHeight = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        NSString *lower = label.lowercaseString;
        NSString *target = title.lowercaseString;
        double width = [rect[@"width"] doubleValue], y = [rect[@"y"] doubleValue];
        if ([lower isEqualToString:target] && width >= 20 && width <= 120 &&
            y >= 0 && y < screenHeight * 0.6) pin = YES;
        if ([lower hasPrefix:target] && width >= 200 && y >= screenHeight * 0.45) card = YES;
    }
    if (pin && card) return YES;
    if (!card) return NO;
    // Some 3D landmark views expose the place card to AX but render the
    // selected landmark label only into the map image.
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class] ||
            [item[@"text"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
        NSDictionary *rect = item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double y = [rect[@"y"] doubleValue], width = [rect[@"width"] doubleValue];
        if (y >= screenHeight * 0.12 && y < screenHeight * 0.45 &&
            width >= 40 && width <= 160) return YES;
    }
    return NO;
}

static BOOL BBUnlockedObservation(NSDictionary *observation) {
    NSDictionary *state = observation[@"device_state"];
    return [state[@"locked_known"] boolValue] && ![state[@"locked"] boolValue] &&
        [state[@"screen_on_known"] boolValue] && [state[@"screen_on"] boolValue];
}

static BOOL BBRecentObservation(NSDictionary *observation) {
    id value = observation[@"timestamp"];
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double age = NSDate.date.timeIntervalSince1970 - [value doubleValue];
    return isfinite(age) && age >= 0 && age <= 8;
}

static BOOL BBMapSearchInputReady(NSDictionary *observation) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return NO;
    BOOL searchField = NO, keyboardSubmit = NO;
    double height = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        NSString *lower = label.lowercaseString;
        double y = [rect[@"y"] doubleValue];
        if (([lower containsString:@"search field"] || [lower containsString:@"搜索"] ||
             [lower containsString:@"搜尋"]) && y >= 0 && y < height / 3) searchField = YES;
        if (([lower isEqualToString:@"search"] || [lower isEqualToString:@"搜索"] ||
             [lower isEqualToString:@"搜尋"]) && y > height * 0.65) keyboardSubmit = YES;
    }
    return searchField && keyboardSubmit;
}

static BOOL BBMapQueryInSearchField(NSDictionary *observation, NSString *query) {
    if (!query.length) return NO;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isEqualToString:@"Search field"]) continue;
        NSArray *aliases = item[@"aliases"];
        if (![aliases isKindOfClass:NSArray.class]) continue;
        for (NSString *alias in aliases)
            if ([alias isKindOfClass:NSString.class] &&
                [alias caseInsensitiveCompare:query] == NSOrderedSame) return YES;
    }
    return NO;
}

static BOOL BBMapSearchTapAllowed(NSDictionary *observation, double x, double y) {
    double height = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        NSString *lower = label.lowercaseString;
        if (![@[@"search field", @"search maps", @"search", @"搜索地图", @"搜索", @"搜尋"] containsObject:lower]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], rowHeight = [rect[@"height"] doubleValue];
        if (width < 40 || rowHeight < 20 || rowHeight > 100 || top < 0 || top > height * 0.8) continue;
        if (x >= left && x < left + width && y >= top && y < top + rowHeight) return YES;
    }
    return NO;
}

static BOOL BBMapClearTextTapAllowed(NSDictionary *observation, NSString *query,
                                      double x, double y) {
    if (!BBMapSearchInputReady(observation) ||
        BBMapQueryInSearchField(observation, query)) return NO;
    double screenHeight = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isEqualToString:@"Clear text"]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (width < 15 || width > 50 || height < 15 || height > 50 ||
            top < 0 || top >= screenHeight / 3) continue;
        if (x >= left && x <= left + width && y >= top && y <= top + height)
            return YES;
    }
    return NO;
}

static NSDictionary *BBMapFixedClearTextAction(NSDictionary *observation, NSString *query) {
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isEqualToString:@"Clear text"]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2;
        double y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2;
        if (BBMapClearTextTapAllowed(observation, query, x, y))
            return @{@"action": @"tap", @"x": @(x), @"y": @(y)};
    }
    return nil;
}

static BOOL BBMapSuggestionTapAllowed(NSDictionary *observation, NSString *query, double x, double y) {
    if (!BBMapSearchInputReady(observation)) return NO;
    NSString *title = BBMapResultName(query);
    if (title.length < 5) return NO;
    BOOL queryInField = NO, matchingSuggestion = NO;
    double suggestionLeft = DBL_MAX, suggestionRight = 0;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        if ([label isEqualToString:@"Search field"] &&
            [item[@"aliases"] isKindOfClass:NSArray.class])
            for (NSString *alias in item[@"aliases"])
                if ([alias isKindOfClass:NSString.class] &&
                    [alias caseInsensitiveCompare:query] == NSOrderedSame) queryInField = YES;
        if ([label.lowercaseString hasPrefix:[title.lowercaseString stringByAppendingString:@","]] &&
            [label.lowercaseString rangeOfString:@"search nearby"].location == NSNotFound &&
            [rect[@"width"] doubleValue] >= 200) {
            matchingSuggestion = YES;
            suggestionLeft = MIN(suggestionLeft, [rect[@"x"] doubleValue]);
            suggestionRight = MAX(suggestionRight, [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue]);
        }
    }
    if (!queryInField || !matchingSuggestion) return NO;
    double screenHeight = [observation[@"screen"][@"height"] doubleValue];
    // The Maps AX suggestion rectangle can be offset upward on iOS 26.
    // Use the actual screenshot OCR bounds for the tap, corroborated by AX.
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class] ||
            [item[@"text"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
        NSDictionary *rect = item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (width < 50 || height < 10 || top < screenHeight * 0.11 ||
            top >= screenHeight * 0.7) continue;
        BOOL nearbySearch = NO;
        for (NSDictionary *other in observation[@"ocr"][@"texts"]) {
            if (![other isKindOfClass:NSDictionary.class] ||
                ![other[@"text"] isKindOfClass:NSString.class]) continue;
            double otherTop = [other[@"rect"][@"y"] doubleValue];
            if (otherTop > top + height && otherTop < top + height + 35 &&
                [@[@"Search Nearby", @"搜索附近", @"搜尋附近"] containsObject:other[@"text"]]) {
                nearbySearch = YES; break;
            }
        }
        if (nearbySearch) continue;
        if (x >= suggestionLeft && x <= suggestionRight &&
            y >= top - 20 && y <= top + height + 42) return YES;
    }
    return NO;
}

static NSDictionary *BBMapFixedSuggestionAction(NSDictionary *observation, NSString *query) {
    NSString *title = BBMapResultName(query);
    if (title.length < 5) return nil;
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class] ||
            [item[@"text"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
        NSDictionary *rect = item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2;
        double y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2;
        if (BBMapSuggestionTapAllowed(observation, query, x, y))
            return @{@"action": @"tap", @"x": @(x), @"y": @(y)};
    }
    return nil;
}

static BOOL BBMapResultRowTapAllowed(NSDictionary *observation, NSString *query,
                                      double x, double y) {
    if (!BBMapQueryInSearchField(observation, query)) return NO;
    NSString *title = BBMapResultName(query);
    if (title.length < 5) return NO;
    double screenWidth = [observation[@"screen"][@"width"] doubleValue];
    double screenHeight = [observation[@"screen"][@"height"] doubleValue];
    BOOL exactResultRow = NO;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        if ([label.lowercaseString hasPrefix:
                [title.lowercaseString stringByAppendingString:@","]] &&
            [rect[@"width"] doubleValue] >= screenWidth * 0.7 &&
            [label.lowercaseString rangeOfString:@"search nearby"].location == NSNotFound) {
            exactResultRow = YES;
            break;
        }
    }
    if (!exactResultRow) return NO;
    // Maps result-list AX rectangles are shifted upward on iOS 26. Require
    // the exact AX row and the same title in the lower sheet's OCR before tap.
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class] ||
            [item[@"text"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
        NSDictionary *rect = item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (width < 50 || height < 10 || top < screenHeight * 0.55 ||
            top >= screenHeight * 0.9) continue;
        if (x >= left && x <= left + width && y >= top && y <= top + height)
            return YES;
    }
    return NO;
}

static NSDictionary *BBMapFixedResultRowAction(NSDictionary *observation, NSString *query) {
    NSString *title = BBMapResultName(query);
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class] ||
            [item[@"text"] caseInsensitiveCompare:title] != NSOrderedSame) continue;
        NSDictionary *rect = item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2;
        double y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2;
        if (BBMapResultRowTapAllowed(observation, query, x, y))
            return @{@"action": @"tap", @"x": @(x), @"y": @(y)};
    }
    return nil;
}

static NSDictionary *BBMapFixedSelectionAction(NSDictionary *observation, NSString *query,
                                                 NSArray *history) {
    BOOL alreadyTyped = NO;
    for (NSDictionary *item in history)
        if ([item[@"action"] isEqualToString:@"input_text"]) alreadyTyped = YES;
    return BBMapFixedSuggestionAction(observation, query) ?:
        BBMapFixedResultRowAction(observation, query) ?:
        (alreadyTyped ? nil : BBMapFixedClearTextAction(observation, query));
}

static NSString *BBNoteTimestamp(NSDictionary *observation) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return nil;
    for (NSDictionary *item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSArray *aliases = item[@"aliases"];
        NSString *label = item[@"text"];
        if (![aliases isKindOfClass:NSArray.class] || ![label isKindOfClass:NSString.class] ||
            label.length > 80) continue;
        if ([aliases containsObject:@"Timestamp"] && [aliases containsObject:@"Created"])
            return label;
    }
    return nil;
}

static BOOL BBNoteEditorReady(NSDictionary *observation) {
    NSArray *elements = observation[@"ui"][@"elements"];
    if (![elements isKindOfClass:NSArray.class] || !BBNoteTimestamp(observation)) return NO;
    BOOL done = NO, blankEditor = NO, keyboard = NO;
    double height = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        double y = [rect[@"y"] doubleValue];
        if (([label isEqualToString:@"Done"] || [label isEqualToString:@"完成"]) && y < 120) done = YES;
        if (([label isEqualToString:@"Note"] || [label isEqualToString:@"备忘录"]) &&
            [rect[@"width"] doubleValue] > 200 && y < 200) blankEditor = YES;
        if (([label isEqualToString:@"return"] || [label isEqualToString:@"换行"]) &&
            y > height * 0.55) keyboard = YES;
    }
    return done && blankEditor && keyboard;
}

static BOOL BBNoteBlankUnfocused(NSDictionary *observation) {
    if (!BBNoteTimestamp(observation)) return NO;
    double height = [observation[@"screen"][@"height"] doubleValue];
    BOOL blankCanvas = NO;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        if ([@[@"Done", @"完成", @"return", @"换行"] containsObject:label]) return NO;
        if ([@[@"Note", @"备忘录"] containsObject:label] &&
            [rect[@"width"] doubleValue] > 200 && [rect[@"height"] doubleValue] > height * 0.55 &&
            [rect[@"y"] doubleValue] < 100) blankCanvas = YES;
    }
    if (!blankCanvas || ![observation[@"ocr"][@"texts"] isKindOfClass:NSArray.class]) return NO;
    for (NSDictionary *item in observation[@"ocr"][@"texts"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *text = item[@"text"];
        double y = [item[@"rect"][@"y"] doubleValue];
        if ([text isKindOfClass:NSString.class] &&
            [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length &&
            y >= 120 && y < height * 0.55) return NO;
    }
    return YES;
}

static BOOL BBNoteFocusPoint(NSDictionary *observation, double x, double y) {
    double width = [observation[@"screen"][@"width"] doubleValue];
    double height = [observation[@"screen"][@"height"] doubleValue];
    if (!BBNoteBlankUnfocused(observation) || x < 40 || x > width - 40 ||
        y < 120 || y > height * 0.5) return NO;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![@[@"Note", @"备忘录"] containsObject:item[@"text"]]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double left = [rect[@"x"] doubleValue], top = [rect[@"y"] doubleValue];
        if (x >= left && x <= left + [rect[@"width"] doubleValue] &&
            y >= top && y <= top + [rect[@"height"] doubleValue]) return YES;
    }
    return NO;
}

static NSDictionary *BBNoteBackAction(NSDictionary *observation) {
    if (!BBNoteTimestamp(observation)) return nil;
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![@[@"Notes", @"备忘录"] containsObject:item[@"text"]]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue], y = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        if (x < 0 || x > 80 || y < 30 || y > 90 ||
            width < 20 || width > 100 || height < 20 || height > 60) continue;
        return @{@"action": @"tap", @"x": @(x + width / 2), @"y": @(y + height / 2)};
    }
    return nil;
}

static BOOL BBNoteInList(NSDictionary *observation, NSString *content) {
    if (BBNoteTimestamp(observation)) return NO;
    BOOL newButton = NO, matchingRow = NO;
    NSString *prefix = [content stringByAppendingString:@","];
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class]) continue;
        NSString *label = item[@"text"];
        if ([@[@"New note", @"新建备忘录", @"Compose"] containsObject:label]) newButton = YES;
        if ([label isEqualToString:content] || [label hasPrefix:prefix]) matchingRow = YES;
    }
    return newButton && matchingRow;
}

static NSDictionary *BBMapInitialLaunch(NSDictionary *observation, NSArray *history) {
    if (history.count ||
        [observation[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"])
        return nil;
    return @{@"action": @"launch_app", @"bundle_id": @"com.apple.Maps"};
}

static NSDictionary *BBFixedNoteAction(NSString *task, NSDictionary *observation, NSArray *history) {
    NSString *content = BBNoteText(task);
    if (!content) return BBError(@"Invalid note task");
    NSString *foreground = observation[@"frontmost_app"][@"bundleId"];
    if (![foreground isEqualToString:@"com.apple.mobilenotes"])
        return history.count == 0 ? @{@"action": @"launch_app", @"bundle_id": @"com.apple.mobilenotes"} :
            BBError(@"Notes left the foreground");
    NSMutableArray<NSString *> *uiActions = [NSMutableArray array];
    for (NSDictionary *item in history)
        if (![item[@"action"] isEqualToString:@"launch_app"]) [uiActions addObject:item[@"action"] ?: @""];
    NSUInteger uiSteps = uiActions.count;
    if (uiSteps == 0 && BBNoteInList(observation, content))
        return BBError(@"A note with this exact title already exists");
    BOOL newOnly = uiSteps == 1 && [uiActions[0] isEqualToString:@"tap"];
    BOOL focused = uiSteps == 2 &&
        [uiActions[0] isEqualToString:@"tap"] && [uiActions[1] isEqualToString:@"tap"];
    BOOL typedDirect = uiSteps == 2 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"input_text"];
    BOOL typedFocused = uiSteps == 3 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"];
    BOOL savedDirect = uiSteps == 3 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"input_text"] && [uiActions[2] isEqualToString:@"tap"];
    BOOL savedFocused = uiSteps == 4 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"] &&
        [uiActions[3] isEqualToString:@"tap"];
    BOOL listedDirect = uiSteps == 4 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"input_text"] && [uiActions[2] isEqualToString:@"tap"] &&
        [uiActions[3] isEqualToString:@"tap"];
    BOOL listedFocused = uiSteps == 5 && [uiActions[0] isEqualToString:@"tap"] &&
        [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"] &&
        [uiActions[3] isEqualToString:@"tap"] && [uiActions[4] isEqualToString:@"tap"];
    if ((newOnly || focused) &&
        BBNoteEditorReady(observation) &&
        !BBVisibleContains(observation, content))
        return @{@"action": @"input_text", @"text": content};
    if (listedDirect || listedFocused)
        return BBNoteInList(observation, content) ? @{@"action": @"done"} :
            BBError(@"New note missing from list");
    if (savedDirect || savedFocused) {
        if (!BBVisibleContains(observation,
            [content substringToIndex:MIN((NSUInteger)12, content.length)]))
            return BBError(@"Notes editor not in expected state");
        return BBNoteBackAction(observation) ?: BBError(@"Notes back control unavailable");
    }
    if (newOnly && BBNoteBlankUnfocused(observation)) {
        double x = [observation[@"screen"][@"width"] doubleValue] * 0.2;
        double y = [observation[@"screen"][@"height"] doubleValue] * 0.2;
        if (BBNoteFocusPoint(observation, x, y))
            return @{@"action": @"tap", @"x": @(x), @"y": @(y)};
    }
    BOOL doneStep = typedDirect || typedFocused;
    if (uiSteps != 0 && !doneStep) return BBError(@"Notes editor not in expected state");
    if (doneStep && !BBVisibleContains(observation,
        [content substringToIndex:MIN((NSUInteger)12, content.length)]))
        return BBError(@"Notes editor not in expected state");
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *label = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![label isKindOfClass:NSString.class] || ![rect isKindOfClass:NSDictionary.class]) continue;
        BOOL match = uiSteps == 0 ?
            ([@[@"New note", @"新建备忘录", @"Compose"] containsObject:label]) :
            ([@[@"Done", @"完成"] containsObject:label]);
        if (!match) continue;
        double x = [rect[@"x"] doubleValue], y = [rect[@"y"] doubleValue];
        double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
        double screenWidth = [observation[@"screen"][@"width"] doubleValue];
        double screenHeight = [observation[@"screen"][@"height"] doubleValue];
        if (width < 20 || height < 20 || x < 0 || y < 0 ||
            x + width > screenWidth || y + height > screenHeight ||
            (doneStep && y >= 120)) continue;
        return @{@"action": @"tap", @"x": @(x + width / 2), @"y": @(y + height / 2)};
    }
    return BBError(@"Notes control unavailable");
}

static BOOL BBValidAction(NSDictionary *action, NSDictionary *observation, NSString *task,
                          NSArray *history, BOOL allowUI, BOOL autoMap, BOOL autoNote) {
    NSString *name = action[@"action"];
    if (![@[@"launch_app", @"tap", @"swipe", @"input_text", @"press_key", @"done"] containsObject:name]) return NO;
    if (!BBUnlockedObservation(observation)) return NO;
    NSString *requested = BBRequestedApp(task);
    NSString *foreground = observation[@"frontmost_app"][@"bundleId"];
    if (autoMap) {
        NSString *query = BBMapQuery(task);
        if (!query) return NO;
        NSMutableArray *uiHistory = [NSMutableArray array];
        for (NSDictionary *item in history)
            if (![@"launch_app" isEqualToString:item[@"action"]]) [uiHistory addObject:item[@"action"] ?: @""];
        NSUInteger uiSteps = uiHistory.count;
        if ([name isEqualToString:@"done"])
            return [foreground isEqualToString:@"com.apple.Maps"] &&
                BBMapResultVisible(observation, query);
        if ([name isEqualToString:@"launch_app"])
            return history.count == 0 && [action[@"bundle_id"] isEqualToString:@"com.apple.Maps"];
        if (!allowUI || ![foreground isEqualToString:@"com.apple.Maps"]) return NO;
        if ([name isEqualToString:@"tap"] && uiSteps <= 2 &&
            BBMapFixedClearTextAction(observation, query) &&
            ![uiHistory containsObject:@"input_text"]) {
            id x = action[@"x"], y = action[@"y"];
            if ([x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
                isfinite([x doubleValue]) && isfinite([y doubleValue]) &&
                BBMapClearTextTapAllowed(observation, query,
                                          [x doubleValue], [y doubleValue])) return YES;
        }
        if ([name isEqualToString:@"tap"] &&
            (uiSteps == 0 || (uiSteps == 1 && [uiHistory[0] isEqualToString:@"tap"]))) {
            id x = action[@"x"], y = action[@"y"];
            if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
                !isfinite([x doubleValue]) || !isfinite([y doubleValue])) return NO;
            BOOL search = BBMapSearchTapAllowed(observation, [x doubleValue], [y doubleValue]);
            if (search) return YES;
            if (BBMapSuggestionTapAllowed(observation, query,
                                          [x doubleValue], [y doubleValue])) return YES;
            double height = [observation[@"screen"][@"height"] doubleValue];
            return uiSteps == 0 && [y doubleValue] > height * 0.4 &&
                [y doubleValue] < height * 0.8 &&
                BBElementContainsPoint(observation, [x doubleValue], [y doubleValue],
                                       @[@"close", @"关闭"], NO);
        }
        if ([name isEqualToString:@"tap"] && uiSteps > 0 &&
            [uiHistory.lastObject isEqualToString:@"input_text"]) {
            id x = action[@"x"], y = action[@"y"];
            return [x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
                isfinite([x doubleValue]) && isfinite([y doubleValue]) &&
                BBMapSuggestionTapAllowed(observation, query, [x doubleValue], [y doubleValue]);
        }
        if ([name isEqualToString:@"tap"] && uiSteps > 0 &&
            [uiHistory.lastObject isEqualToString:@"press_key"]) {
            id x = action[@"x"], y = action[@"y"];
            return [x isKindOfClass:NSNumber.class] && [y isKindOfClass:NSNumber.class] &&
                isfinite([x doubleValue]) && isfinite([y doubleValue]) &&
                BBMapResultRowTapAllowed(observation, query, [x doubleValue], [y doubleValue]);
        }
        BOOL onlyTaps = uiSteps <= 3;
        for (NSString *prior in uiHistory) if (![prior isEqualToString:@"tap"]) onlyTaps = NO;
        if ([name isEqualToString:@"input_text"] && BBMapSearchInputReady(observation) &&
            !BBMapQueryInSearchField(observation, query) &&
            !BBMapFixedClearTextAction(observation, query) && onlyTaps)
            return [action[@"text"] isKindOfClass:NSString.class] && [action[@"text"] isEqualToString:query];
        BOOL tapsThenInput = uiSteps >= 1 && uiSteps <= 4 &&
            [uiHistory.lastObject isEqualToString:@"input_text"];
        for (NSUInteger i = 0; i + 1 < uiSteps; i++)
            if (![uiHistory[i] isEqualToString:@"tap"]) tapsThenInput = NO;
        if ([name isEqualToString:@"press_key"] &&
            ((uiSteps == 0 && BBMapSearchInputReady(observation)) || tapsThenInput))
            return [action[@"key"] isKindOfClass:NSString.class] && [action[@"key"] isEqualToString:@"enter"] &&
                BBMapQueryInSearchField(observation, query);
        return NO;
    }
    if (autoNote) {
        NSString *content = BBNoteText(task);
        if (!content) return NO;
        NSMutableArray<NSString *> *uiActions = [NSMutableArray array];
        for (NSDictionary *item in history)
            if (![@"launch_app" isEqualToString:item[@"action"]]) [uiActions addObject:item[@"action"] ?: @""];
        NSUInteger uiSteps = uiActions.count;
        BOOL newOnly = uiSteps == 1 && [uiActions[0] isEqualToString:@"tap"];
        BOOL focused = uiSteps == 2 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"tap"];
        BOOL typedDirect = uiSteps == 2 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"input_text"];
        BOOL typedFocused = uiSteps == 3 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"];
        BOOL savedDirect = uiSteps == 3 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"input_text"] && [uiActions[2] isEqualToString:@"tap"];
        BOOL savedFocused = uiSteps == 4 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"] &&
            [uiActions[3] isEqualToString:@"tap"];
        BOOL listedDirect = uiSteps == 4 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"input_text"] && [uiActions[2] isEqualToString:@"tap"] &&
            [uiActions[3] isEqualToString:@"tap"];
        BOOL listedFocused = uiSteps == 5 && [uiActions[0] isEqualToString:@"tap"] &&
            [uiActions[1] isEqualToString:@"tap"] && [uiActions[2] isEqualToString:@"input_text"] &&
            [uiActions[3] isEqualToString:@"tap"] && [uiActions[4] isEqualToString:@"tap"];
        NSString *prefix = [content substringToIndex:MIN((NSUInteger)12, content.length)];
        if ([name isEqualToString:@"done"])
            return [foreground isEqualToString:@"com.apple.mobilenotes"] &&
                (listedDirect || listedFocused) && BBNoteInList(observation, content);
        if ([name isEqualToString:@"launch_app"])
            return history.count == 0 && [action[@"bundle_id"] isEqualToString:@"com.apple.mobilenotes"];
        if (!allowUI || ![foreground isEqualToString:@"com.apple.mobilenotes"]) return NO;
        if ([name isEqualToString:@"tap"] &&
            (uiSteps == 0 || newOnly || typedDirect || typedFocused || savedDirect || savedFocused)) {
            id x = action[@"x"], y = action[@"y"];
            if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] ||
                !isfinite([x doubleValue]) || !isfinite([y doubleValue])) return NO;
            if (newOnly) return BBNoteFocusPoint(observation, [x doubleValue], [y doubleValue]);
            if (savedDirect || savedFocused) {
                NSDictionary *back = BBNoteBackAction(observation);
                return back && BBVisibleContains(observation, prefix) &&
                    [x doubleValue] == [back[@"x"] doubleValue] &&
                    [y doubleValue] == [back[@"y"] doubleValue];
            }
            if ((typedDirect || typedFocused) && !BBVisibleContains(observation, prefix)) return NO;
            return BBElementContainsPoint(observation, [x doubleValue], [y doubleValue],
                uiSteps == 0 ? @[@"新建", @"new note", @"compose"] : @[@"完成", @"done"], uiSteps == 0);
        }
        if ([name isEqualToString:@"input_text"] && (newOnly || focused))
            return BBNoteEditorReady(observation) && !BBVisibleContains(observation, content) &&
                [action[@"text"] isKindOfClass:NSString.class] &&
                [action[@"text"] isEqualToString:content];
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
    fprintf(stdout, "Pending action: %s\nType yes to run this step: ", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
    fflush(stdout);
    char answer[16] = {0};
    return fgets(answer, sizeof(answer), stdin) && !strncmp(answer, "yes", 3);
}

static BOOL BBFreshUICompatible(NSString *action, BOOL sameUI, BOOL sameNoteEditor,
                                BOOL sameNoteControl, BOOL autoMap) {
    // Launching a named, allowlisted app does not use coordinates or text from
    // the source UI. BeanBao can update its status while the fresh observation
    // is captured; keep exact UI matching for actions that use that UI.
    return [action isEqualToString:@"launch_app"] || autoMap || sameUI ||
        sameNoteEditor || sameNoteControl;
}

// One bounded Notes action for the Swift harness. Keep the existing Notes
// planner and policy as the authority while the runtime owns the step loop.
typedef NSDictionary * (^BBNoteBridgeRequest)(NSDictionary *request);

static NSDictionary *BBNoteStep(NSString *task, NSArray *history, BBNoteBridgeRequest bridge) {
    if (!BBNoteText(task) || BBHasSecret(task) || history.count > 12)
        return @{@"ok": @NO, @"error": @"invalid_task"};
    NSDictionary *lease = bridge(@{@"op": @"wake_lease", @"mode": @"renew"});
    if (![lease[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"wake_lease"};
    NSDictionary *observation = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
    if (![observation[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"observe"};
    if (!BBUnlockedObservation(observation)) return @{@"ok": @NO, @"error": @"locked"};
    BOOL priorUIAction = NO;
    for (NSDictionary *item in history)
        if (![item[@"action"] isEqualToString:@"launch_app"]) priorUIAction = YES;
    BOOL listVerified = priorUIAction && BBNoteInList(observation, BBNoteText(task));
    if (priorUIAction && !listVerified &&
        (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"]))) {
        for (NSUInteger retry = 0; retry < 6; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.mobilenotes"])
                break;
            observation = settled;
            if (!BBHasSecret(observation[@"ui"]) && !BBHasSecret(observation[@"ocr"])) break;
        }
    }
    NSDictionary *action = BBFixedNoteAction(task, observation, history);
    BOOL justLaunchedNotes = history.count == 1 &&
        [history.lastObject[@"action"] isEqualToString:@"launch_app"];
    if ((priorUIAction || justLaunchedNotes) &&
        (action[@"error"] || !BBValidAction(action, observation, task, history, YES, NO, YES))) {
        for (NSUInteger retry = 0; retry < 10; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.mobilenotes"])
                break;
            observation = settled;
            if (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"])) continue;
            action = BBFixedNoteAction(task, observation, history);
            if (!action[@"error"] &&
                BBValidAction(action, observation, task, history, YES, NO, YES)) break;
        }
    }
    BOOL safeNewTap = !priorUIAction && [action[@"action"] isEqualToString:@"tap"];
    BOOL safeListDone = [action[@"action"] isEqualToString:@"done"];
    if (action[@"error"] ||
        (!safeNewTap && !safeListDone &&
         (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"]))) ||
        !BBValidAction(action, observation, task, history, YES, NO, YES)) {
        BBAudit(@"step", @"com.apple.mobilenotes", @"policy_block", @"blocked");
        return @{@"ok": @NO, @"error": @"note_state"};
    }
    if (safeListDone) {
        BBAudit(@"step", @"com.apple.mobilenotes", @"done", @"ok");
        return @{@"ok": @YES, @"done": @YES};
    }

    NSString *name = action[@"action"];
    NSDictionary *fresh = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
    BOOL sameUI = [fresh[@"ui"] isEqual:observation[@"ui"]];
    BOOL sameEditor = [name isEqualToString:@"input_text"] &&
        BBNoteEditorReady(observation) && BBNoteEditorReady(fresh) &&
        [BBNoteTimestamp(observation) isEqualToString:BBNoteTimestamp(fresh)];
    BOOL sameControl = [name isEqualToString:@"tap"] &&
        BBValidAction(action, fresh, task, history, YES, NO, YES);
    BOOL sameApp = [fresh[@"frontmost_app"][@"bundleId"]
        isEqual:observation[@"frontmost_app"][@"bundleId"]];
    BOOL allowed = BBValidAction(action, fresh, task, history, YES, NO, YES);
    BOOL recent = BBRecentObservation(fresh);
    if (![fresh[@"ok"] boolValue] ||
        (!safeNewTap && (BBHasSecret(fresh[@"ui"]) || BBHasSecret(fresh[@"ocr"]))) ||
        !BBFreshUICompatible(name, sameUI, sameEditor, sameControl, NO) ||
        !sameApp || !allowed || !recent) {
        BBAudit(@"step", @"com.apple.mobilenotes", @"policy_block", @"blocked");
        return @{@"ok": @NO, @"error": @"fresh_state"};
    }
    NSMutableDictionary *request = [action mutableCopy];
    request[@"op"] = @"act";
    request[@"observation_id"] = fresh[@"observation_id"];
    if (![bridge(request)[@"ok"] boolValue]) {
        BBAudit(@"step", @"com.apple.mobilenotes", name, @"failed");
        return @{@"ok": @NO, @"error": @"act"};
    }
    BBAudit(@"step", @"com.apple.mobilenotes", name, @"ok");
    return @{@"ok": @YES, @"done": @NO, @"action": action};
}

char *BBNoteStepJSON(const char *taskText, const char *historyJSON) {
    @autoreleasepool {
        if (!taskText || !historyJSON) return NULL;
        NSString *task = [NSString stringWithUTF8String:taskText];
        NSData *historyData = [[NSString stringWithUTF8String:historyJSON] dataUsingEncoding:NSUTF8StringEncoding];
        if (!task || !historyData) return NULL;
        id history = [NSJSONSerialization JSONObjectWithData:historyData options:0 error:nil];
        if (![history isKindOfClass:NSArray.class]) return NULL;
        for (id item in history) if (![item isKindOfClass:NSDictionary.class]) return NULL;
        NSDictionary *result = BBNoteStep(task, history, ^NSDictionary *(NSDictionary *request) {
            return BBBridge(request);
        });
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!encoded || encoded.length > 8192) return NULL;
        char *copy = malloc(encoded.length + 1);
        if (!copy) return NULL;
        memcpy(copy, encoded.bytes, encoded.length);
        copy[encoded.length] = '\0';
        return copy;
    }
}

typedef NSDictionary * (^BBMapActionProvider)(NSString *task, NSDictionary *observation, NSArray *history);

static NSDictionary *BBFixedMapAction(NSString *task, NSDictionary *observation, NSArray *history) {
    NSString *query = BBMapQuery(task);
    if (!query) return BBError(@"local_state");
    BOOL submittedSuggestion = [history.lastObject[@"action"] isEqualToString:@"tap"];
    if (submittedSuggestion) {
        submittedSuggestion = NO;
        for (NSDictionary *item in history)
            if ([item[@"action"] isEqualToString:@"input_text"]) {
                submittedSuggestion = YES;
                break;
            }
    }
    if (BBMapResultVisible(observation, query) ||
        [history.lastObject[@"action"] isEqualToString:@"press_key"] || submittedSuggestion)
        return @{@"action": @"done"};
    if (BBMapSearchInputReady(observation)) {
        if (BBMapQueryInSearchField(observation, query))
            return @{@"action": @"press_key", @"key": @"enter"};
        if ([history.lastObject[@"action"] isEqualToString:@"input_text"])
            return BBError(@"local_state");
        NSDictionary *clear = BBMapFixedClearTextAction(observation, query);
        if (clear) return clear;
        return @{@"action": @"input_text", @"text": query};
    }
    double screenHeight = [observation[@"screen"][@"height"] doubleValue];
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class]) continue;
        NSString *label = [item[@"text"] lowercaseString];
        if (![@[@"close", @"关闭"] containsObject:label]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2;
        double y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2;
        NSDictionary *candidate = @{@"action": @"tap", @"x": @(x), @"y": @(y)};
        if (y > screenHeight * 0.4 && y < screenHeight * 0.8 &&
            BBValidAction(candidate, observation, task, history, YES, YES, NO)) return candidate;
    }
    for (NSDictionary *item in observation[@"ui"][@"elements"]) {
        if (![item isKindOfClass:NSDictionary.class] ||
            ![item[@"text"] isKindOfClass:NSString.class]) continue;
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![rect isKindOfClass:NSDictionary.class]) continue;
        double x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2;
        double y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2;
        if (!BBMapSearchTapAllowed(observation, x, y)) continue;
        NSDictionary *candidate = @{@"action": @"tap", @"x": @(x), @"y": @(y)};
        if (BBValidAction(candidate, observation, task, history, YES, YES, NO)) return candidate;
    }
    return BBError(@"local_state");
}

static NSDictionary *BBMapStep(NSString *task, NSArray *history,
                                BBNoteBridgeRequest bridge, BBMapActionProvider model,
                                BOOL captureScreenshotForModel) {
    NSString *query = BBMapQuery(task);
    if (!query || history.count >= 20) return @{@"ok": @NO, @"error": @"invalid_task"};
    if (BBHasSecret(task)) return @{@"ok": @NO, @"error": @"sensitive"};
    NSDictionary *lease = bridge(@{@"op": @"wake_lease", @"mode": @"renew"});
    if (![lease[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"wake_lease"};
    NSDictionary *observation = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
    if (![observation[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"observe"};
    if (!BBUnlockedObservation(observation)) return @{@"ok": @NO, @"error": @"locked"};
    NSDictionary *fixedLaunch = BBMapInitialLaunch(observation, history);
    if (!fixedLaunch &&
        ![observation[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"])
        return @{@"ok": @NO, @"error": @"fresh_state"};
    if (!fixedLaunch && (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"])))
        return @{@"ok": @NO, @"error": @"sensitive"};
    NSDictionary *fixedAction = fixedLaunch ?: (BBMapResultVisible(observation, query) ?
        @{@"action": @"done"} : BBMapFixedSelectionAction(observation, query, history));
    if (!fixedAction && captureScreenshotForModel) {
        NSDictionary *local = BBFixedMapAction(task, observation, history);
        if (([local[@"action"] isEqualToString:@"input_text"] ||
             [local[@"action"] isEqualToString:@"press_key"]) &&
            BBValidAction(local, observation, task, history, YES, YES, NO))
            fixedAction = local;
    }
    if (!fixedAction && [history.lastObject[@"action"] isEqualToString:@"input_text"] &&
        !BBMapQueryInSearchField(observation, query)) {
        for (NSUInteger retry = 0; retry < 5; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"observe"};
            if (!BBUnlockedObservation(settled)) return @{@"ok": @NO, @"error": @"locked"};
            if (![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"])
                return @{@"ok": @NO, @"error": @"fresh_state"};
            if (BBHasSecret(settled[@"ui"]) || BBHasSecret(settled[@"ocr"]))
                return @{@"ok": @NO, @"error": @"sensitive"};
            observation = settled;
            if (BBMapResultVisible(observation, query)) {
                fixedAction = @{@"action": @"done"};
                break;
            }
            if (BBMapQueryInSearchField(observation, query)) {
                fixedAction = BBMapFixedSelectionAction(observation, query, history);
                break;
            }
        }
        if (!fixedAction && !BBMapQueryInSearchField(observation, query))
            return @{@"ok": @NO, @"error": @"input_unverified"};
    }
    if (!fixedAction && [history.lastObject[@"action"] isEqualToString:@"input_text"] &&
        [observation[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] &&
        BBMapQueryInSearchField(observation, query)) {
        for (NSUInteger retry = 0; retry < 8; retry++) {
            usleep(500000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] ||
                BBHasSecret(settled[@"ui"]) || BBHasSecret(settled[@"ocr"])) break;
            observation = settled;
            fixedAction = BBMapFixedSelectionAction(observation, query, history);
            if (fixedAction) break;
        }
    }
    if (!fixedAction && captureScreenshotForModel) {
        NSDictionary *visual = bridge(@{@"op": @"observe", @"ui": @YES,
                                        @"ocr": @YES, @"screenshot": @YES});
        if (![visual[@"ok"] boolValue] || !BBUnlockedObservation(visual) ||
            ![visual[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"])
            return @{@"ok": @NO, @"error": @"fresh_state"};
        if (BBHasSecret(visual[@"ui"]) || BBHasSecret(visual[@"ocr"]))
            return @{@"ok": @NO, @"error": @"sensitive"};
        observation = visual;
        fixedAction = BBMapResultVisible(observation, query) ?
            @{@"action": @"done"} : BBMapFixedSelectionAction(observation, query, history);
        if (!fixedAction) {
            NSDictionary *local = BBFixedMapAction(task, observation, history);
            if (([local[@"action"] isEqualToString:@"input_text"] ||
                 [local[@"action"] isEqualToString:@"press_key"] ||
                 (history.count > 0 && [local[@"action"] isEqualToString:@"tap"])) &&
                BBValidAction(local, observation, task, history, YES, YES, NO))
                fixedAction = local;
        }
    }
    // Opening Maps search can briefly leave AX with no usable controls. Give
    // the local planner a bounded chance to see the focused search field.
    if (!fixedAction && !captureScreenshotForModel &&
        [history.lastObject[@"action"] isEqualToString:@"tap"]) {
        for (NSUInteger retry = 0; retry < 8; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue]) return @{@"ok": @NO, @"error": @"observe"};
            if (!BBUnlockedObservation(settled)) return @{@"ok": @NO, @"error": @"locked"};
            if (![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"])
                return @{@"ok": @NO, @"error": @"fresh_state"};
            if (BBHasSecret(settled[@"ui"]) || BBHasSecret(settled[@"ocr"]))
                return @{@"ok": @NO, @"error": @"sensitive"};
            observation = settled;
            NSDictionary *candidate = BBFixedMapAction(task, observation, history);
            if (![candidate[@"error"] isEqualToString:@"local_state"]) break;
        }
    }
    NSDictionary *action = fixedAction ?: model(task, observation, history);
    if (![action isKindOfClass:NSDictionary.class] || action[@"error"])
        return @{@"ok": @NO, @"error": [action[@"error"] isEqualToString:@"local_state"] ?
            @"local_state" : @"model"};
    if ([action[@"action"] isEqualToString:@"input_text"] &&
        [action[@"text"] isEqualToString:query] &&
        !BBValidAction(action, observation, task, history, YES, YES, NO)) {
        for (NSUInteger retry = 0; retry < 5; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || BBHasSecret(settled[@"ui"]) ||
                BBHasSecret(settled[@"ocr"])) break;
            if (BBValidAction(action, settled, task, history, YES, YES, NO)) {
                observation = settled;
                break;
            }
        }
    }
    if ([action[@"action"] isEqualToString:@"done"] &&
        !BBValidAction(action, observation, task, history, YES, YES, NO)) {
        for (NSUInteger retry = 0; retry < 8; retry++) {
            usleep(500000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || BBHasSecret(settled[@"ui"]) ||
                BBHasSecret(settled[@"ocr"])) break;
            if (BBValidAction(action, settled, task, history, YES, YES, NO)) {
                observation = settled;
                break;
            }
        }
    }
    if (!BBValidAction(action, observation, task, history, YES, YES, NO)) {
        BBAudit(@"step", @"com.apple.Maps", @"policy_block", @"blocked");
        return @{@"ok": @NO, @"error": @"policy"};
    }
    NSString *name = action[@"action"];
    if ([name isEqualToString:@"done"]) {
        BBAudit(@"step", @"com.apple.Maps", @"done", @"ok");
        return @{@"ok": @YES, @"done": @YES};
    }
    BOOL verifiedMapTap = [name isEqualToString:@"tap"] &&
        (BBMapSuggestionTapAllowed(observation, query,
                                   [action[@"x"] doubleValue], [action[@"y"] doubleValue]) ||
         BBMapResultRowTapAllowed(observation, query,
                                  [action[@"x"] doubleValue], [action[@"y"] doubleValue]));
    NSDictionary *fresh = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @(verifiedMapTap)});
    BOOL sameApp = [fresh[@"frontmost_app"][@"bundleId"]
        isEqual:observation[@"frontmost_app"][@"bundleId"]];
    BOOL allowed = BBValidAction(action, fresh, task, history, YES, YES, NO);
    BOOL recent = BBRecentObservation(fresh);
    if (![fresh[@"ok"] boolValue] ||
        (!fixedLaunch && (BBHasSecret(fresh[@"ui"]) || BBHasSecret(fresh[@"ocr"]))) ||
        !sameApp || !allowed || !recent) {
        BBAudit(@"step", @"com.apple.Maps", @"policy_block", @"blocked");
        return @{@"ok": @NO, @"error": @"fresh_state"};
    }
    NSMutableDictionary *request = [action mutableCopy];
    request[@"op"] = @"act";
    request[@"observation_id"] = fresh[@"observation_id"];
    if (![bridge(request)[@"ok"] boolValue]) {
        BBAudit(@"step", @"com.apple.Maps", name, @"failed");
        return @{@"ok": @NO, @"error": @"act"};
    }
    BBAudit(@"step", @"com.apple.Maps", name, @"ok");
    return @{@"ok": @YES, @"done": @NO, @"action": action};
}

static char *BBMapStepEncoded(const char *taskText, const char *historyJSON) {
    @autoreleasepool {
        if (!taskText || !historyJSON) return NULL;
        NSString *task = [NSString stringWithUTF8String:taskText];
        NSData *historyData = [[NSString stringWithUTF8String:historyJSON] dataUsingEncoding:NSUTF8StringEncoding];
        if (!task || !historyData) return NULL;
        id history = [NSJSONSerialization JSONObjectWithData:historyData options:0 error:nil];
        if (![history isKindOfClass:NSArray.class]) return NULL;
        for (id item in history) if (![item isKindOfClass:NSDictionary.class]) return NULL;
        static NSDictionary *modelConfig;
        static NSString *modelKey;
        static dispatch_once_t modelOnce;
        dispatch_once(&modelOnce, ^{
            modelConfig = BBModelLoad();
            modelKey = BBModelReadKey(modelConfig[@"provider"]);
        });
        NSDictionary *result = BBExpectedProvider &&
            ![BBExpectedProvider isEqualToString:modelConfig[@"provider"]] ?
            @{@"ok": @NO, @"error": @"model"} : !modelKey ?
            @{@"ok": @NO, @"error": @"key"} :
            BBMapStep(task, history,
                ^NSDictionary *(NSDictionary *request) { return BBBridge(request); },
                ^NSDictionary *(NSString *command, NSDictionary *observation, NSArray *prior) {
                    return BBModelAction(command, observation, prior, modelConfig, modelKey);
                }, YES);
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        if (!encoded || encoded.length > 8192) return NULL;
        char *copy = malloc(encoded.length + 1);
        if (!copy) return NULL;
        memcpy(copy, encoded.bytes, encoded.length);
        copy[encoded.length] = '\0';
        return copy;
    }
}

char *BBMapStepJSON(const char *taskText, const char *historyJSON) {
    return BBMapStepEncoded(taskText, historyJSON);
}

static int BBRun(NSString *task, BOOL claude, BOOL allowUI, BOOL autoMap, BOOL autoNote) {
    if ([task isEqualToString:@"打开通讯录"]) {
        fprintf(stderr, "Use the BeanBao task service to open Contacts\n");
        return 1;
    }
    NSString *auditApp = BBRequestedApp(task);
    NSDictionary *modelConfig = BBModelLoad();
    NSString *key = claude && !autoNote ? BBModelReadKey(modelConfig[@"provider"]) : nil;
    if (claude && !autoNote && !key) { fprintf(stderr, "Model key is not configured or has unsafe permissions\n"); return 1; }
    if ((claude || autoNote) && BBHasSecret(task)) { fprintf(stderr, "The request may contain a key. Model request stopped.\n"); return 1; }
    @try {
    NSMutableArray *history = [NSMutableArray array];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    for (int step = 0; step < 20 && [deadline timeIntervalSinceNow] > 0; step++) {
        NSDictionary *lease = BBBridge(@{@"op": @"wake_lease", @"mode": @"renew"});
        if (![lease[@"ok"] boolValue]) {
            NSString *leaseError = [lease[@"error"] isKindOfClass:NSString.class] ? lease[@"error"] : @"";
            if ([leaseError containsString:@"locked"] ||
                [leaseError containsString:@"screen is off"])
                fprintf(stderr, "Device is locked or screen is off. Model request stopped.\n");
            else fprintf(stderr, "Could not keep the screen awake. Task stopped.\n");
            return 1;
        }
        NSDictionary *observation = BBBridge(@{@"op": @"observe", @"ui": @YES,
            @"ocr": @(claude || autoNote), @"screenshot": @(claude && !autoNote)});
        if (![observation[@"ok"] boolValue]) { fprintf(stderr, "Screen observation failed\n"); return 1; }
        if (!BBUnlockedObservation(observation)) { fprintf(stderr, "Device is locked or screen is off. Model request stopped.\n"); return 1; }
        NSDictionary *fixedMapLaunch = autoMap ? BBMapInitialLaunch(observation, history) : nil;
        BOOL priorNoteUIAction = NO;
        if (autoNote) for (NSDictionary *item in history)
            if (![item[@"action"] isEqualToString:@"launch_app"]) priorNoteUIAction = YES;
        BOOL noteListVerified = autoNote && priorNoteUIAction &&
            BBNoteInList(observation, BBNoteText(task));
        if (autoNote && priorNoteUIAction && !noteListVerified &&
            (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"]))) {
            // Notes can briefly retain the old list behind a new blank editor.
            // Wait for that transition locally; never send the old list to a model.
            for (NSUInteger retry = 0; retry < 6; retry++) {
                usleep(350000);
                NSDictionary *settled = BBBridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
                if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                    ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.mobilenotes"])
                    break;
                observation = settled;
                if (!BBHasSecret(observation[@"ui"]) && !BBHasSecret(observation[@"ocr"])) break;
            }
        }
        NSDictionary *fixedNoteAction = autoNote ? BBFixedNoteAction(task, observation, history) : nil;
        if (autoNote && priorNoteUIAction && fixedNoteAction[@"error"]) {
            for (NSUInteger retry = 0; retry < 6; retry++) {
                usleep(350000);
                NSDictionary *settled = BBBridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
                if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                    ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.mobilenotes"])
                    break;
                observation = settled;
                if (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"])) continue;
                fixedNoteAction = BBFixedNoteAction(task, observation, history);
                if (!fixedNoteAction[@"error"]) break;
            }
        }
        BOOL safeNewNoteTap = autoNote && !priorNoteUIAction &&
            [fixedNoteAction[@"action"] isEqualToString:@"tap"];
        BOOL safeNoteListDone = autoNote && [fixedNoteAction[@"action"] isEqualToString:@"done"];
        if ((claude || autoNote) && !safeNewNoteTap && !safeNoteListDone && !fixedMapLaunch &&
            (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"]))) {
            fprintf(stderr, "The screen may contain a key. Model request stopped.\n"); return 1;
        }
        NSDictionary *fixedMapAction = fixedMapLaunch ?: (autoMap ?
            BBMapFixedSelectionAction(observation, BBMapQuery(task), history) : nil);
        if (autoMap && !fixedMapAction &&
            [history.lastObject[@"action"] isEqualToString:@"input_text"] &&
            [observation[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] &&
            BBVisibleContains(observation, BBMapQuery(task))) {
            // iOS Maps often paints matching suggestions after the input
            // action returns. Give AX and OCR a short chance to agree.
            for (NSUInteger retry = 0; retry < 8; retry++) {
                usleep(500000);
                NSDictionary *settled = BBBridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
                if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                    ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] ||
                    BBHasSecret(settled[@"ui"]) || BBHasSecret(settled[@"ocr"])) break;
                observation = settled;
                fixedMapAction = BBMapFixedSelectionAction(observation, BBMapQuery(task), history);
                if (fixedMapAction) break;
            }
        }
        NSDictionary *action = autoNote ? fixedNoteAction :
            (fixedMapAction ?: BBModelAction(task, observation, history, modelConfig, key));
        if (action[@"error"]) {
            fprintf(stderr, autoNote ? "Notes screen is not safe to use\n" : "Model request or response failed\n");
            return 1;
        }
        // Maps may finish expanding its search card after the model has seen
        // it. Re-observe briefly before rejecting the exact requested input.
        if (autoMap && [action[@"action"] isEqualToString:@"input_text"] &&
            [action[@"text"] isEqualToString:BBMapQuery(task)] &&
            !BBValidAction(action, observation, task, history, allowUI, autoMap, autoNote)) {
            for (NSUInteger retry = 0; retry < 5; retry++) {
                usleep(350000);
                NSDictionary *settled = BBBridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
                if (![settled[@"ok"] boolValue] || BBHasSecret(settled[@"ui"]) ||
                    BBHasSecret(settled[@"ocr"])) break;
                if (BBValidAction(action, settled, task, history, allowUI, autoMap, autoNote)) {
                    observation = settled;
                    break;
                }
            }
        }
        if (autoMap && [action[@"action"] isEqualToString:@"done"] &&
            !BBValidAction(action, observation, task, history, allowUI, autoMap, autoNote)) {
            for (NSUInteger retry = 0; retry < 8; retry++) {
                usleep(500000);
                NSDictionary *settled = BBBridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
                if (![settled[@"ok"] boolValue] || BBHasSecret(settled[@"ui"]) ||
                    BBHasSecret(settled[@"ocr"])) break;
                if (BBValidAction(action, settled, task, history, allowUI, autoMap, autoNote)) {
                    observation = settled;
                    break;
                }
            }
        }
        if (!BBValidAction(action, observation, task, history, allowUI, autoMap, autoNote)) {
            BBAudit(@"step", auditApp, @"policy_block", @"blocked");
            NSString *kind = action[@"action"];
            fprintf(stderr, "Model action was rejected by policy: step %d, type %s\n", step + 1,
                    [kind isKindOfClass:NSString.class] &&
                    [@[@"launch_app", @"tap", @"swipe", @"input_text", @"press_key", @"done"] containsObject:kind]
                        ? kind.UTF8String : "unknown");
            return 1;
        }
        NSString *name = action[@"action"];
        if ([name isEqualToString:@"done"]) {
            BBAudit(@"step", auditApp, @"done", @"ok");
            puts([action[@"summary"] isKindOfClass:NSString.class] ? [action[@"summary"] UTF8String] : "Done");
            return 0;
        }
        if (![name isEqualToString:@"launch_app"] && !autoMap && !autoNote && !BBApprove(action)) { fprintf(stderr, "Action was not approved\n"); return 1; }
        BOOL verifiedMapTap = autoMap && [name isEqualToString:@"tap"] &&
            (BBMapSuggestionTapAllowed(observation, BBMapQuery(task),
                                       [action[@"x"] doubleValue], [action[@"y"] doubleValue]) ||
             BBMapResultRowTapAllowed(observation, BBMapQuery(task),
                                      [action[@"x"] doubleValue], [action[@"y"] doubleValue]));
        NSDictionary *fresh = BBBridge(@{@"op": @"observe", @"ui": @YES,
            @"ocr": @(verifiedMapTap || autoNote)});
        BOOL sameUI = [fresh[@"ui"] isEqual:observation[@"ui"]];
        BOOL sameNoteEditor = autoNote && [name isEqualToString:@"input_text"] &&
            BBNoteEditorReady(observation) && BBNoteEditorReady(fresh) &&
            [BBNoteTimestamp(observation) isEqualToString:BBNoteTimestamp(fresh)];
        BOOL sameNoteControl = autoNote && [name isEqualToString:@"tap"] &&
            BBValidAction(action, fresh, task, history, allowUI, autoMap, autoNote);
        BOOL sameApp = [fresh[@"frontmost_app"][@"bundleId"] isEqual:observation[@"frontmost_app"][@"bundleId"]];
        BOOL allowed = BBValidAction(action, fresh, task, history, allowUI, autoMap, autoNote);
        BOOL recent = BBRecentObservation(fresh);
        if (![fresh[@"ok"] boolValue] ||
            ((claude || autoNote) && !safeNewNoteTap && !fixedMapLaunch &&
             (BBHasSecret(fresh[@"ui"]) || BBHasSecret(fresh[@"ocr"]))) ||
            !BBFreshUICompatible(name, sameUI, sameNoteEditor, sameNoteControl, autoMap) ||
            !sameApp || !allowed || !recent) {
            fprintf(stderr, "Screen verification failed: step %d, UI=%d, app=%d, policy=%d, freshness=%d\n",
                    step + 1, sameUI, sameApp, allowed, recent);
            return 1;
        }
        NSMutableDictionary *request = [action mutableCopy];
        request[@"op"] = @"act"; request[@"observation_id"] = fresh[@"observation_id"];
        NSDictionary *result = BBBridge(request);
        if (![result[@"ok"] boolValue]) {
            BBAudit(@"step", auditApp, name, @"failed");
            fprintf(stderr, "Action failed\n"); return 1;
        }
        BBAudit(@"step", auditApp, name, @"ok");
        [history addObject:action];
    }
    fprintf(stderr, "Task exceeded its time or step limit\n"); return 1;
    } @finally {
        BBReleaseWakeLease();
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--serve")) return BBServe();
        if (argc == 3 && !strcmp(argv[1], "--harness-text")) return BBRunHarnessText(argv[2]);
        if (argc == 3 && !strcmp(argv[1], "--harness-note")) return BBRunHarnessNote(argv[2]);
        if (argc == 4 && !strcmp(argv[1], "--harness-map")) {
            BBExpectedProvider = [NSString stringWithUTF8String:argv[3]];
            return BBRunHarnessMap(argv[2]);
        }
        if (argc == 4 && !strcmp(argv[1], "--workflow-research")) {
            NSString *request = [NSString stringWithUTF8String:argv[2]];
            if (!request.length || request.length > 220 || BBHasSecret(request) ||
                !BBResearchBroadCandidate(request)) {
                fputs("Unsupported research request\n", stderr);
                return 2;
            }
            return BBRunHarnessResearch(argv[2], argv[3]);
        }
        if (argc == 4 && !strcmp(argv[1], "--workflow-research-app")) {
            NSString *request = [NSString stringWithUTF8String:argv[2]];
            if (!request.length || request.length > 220 || BBHasSecret(request) ||
                !BBResearchAppCandidate(request)) {
                fputs("Unsupported research and App Store request\n", stderr);
                return 2;
            }
            return BBRunHarnessResearch(argv[2], argv[3]);
        }
        if (argc == 4 && !strcmp(argv[1], "--workflow-app-store")) {
            NSString *request = [NSString stringWithUTF8String:argv[2]];
            if (!request.length || request.length > 220 || BBHasSecret(request)) {
                fputs("Unsupported App Store request\n", stderr);
                return 2;
            }
            return BBRunHarnessAppStore(argv[2], argv[3]);
        }
        if (argc == 4 && !strcmp(argv[1], "--workflow-delivery-plan")) {
            NSString *request = [NSString stringWithUTF8String:argv[2]];
            if (!request.length || request.length > 220 || BBHasSecret(request)) {
                fputs("Unsupported delivery request\n", stderr);
                return 2;
            }
            return BBRunHarnessDeliveryPlan(argv[2], argv[3]);
        }
        if (argc == 5 && !strcmp(argv[1], "--resolve-task"))
            return BBResolveAndRunTask([NSString stringWithUTF8String:argv[2]],
                                       [NSString stringWithUTF8String:argv[3]],
                                       [NSString stringWithUTF8String:argv[4]]);
        if (argc < 2) { fprintf(stderr, "usage: beanbaod [--approve-ui] 'request'\n"); return 2; }
        BOOL claude = YES, allowUI = NO, autoMap = NO, autoNote = NO;
        NSString *task = nil;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--approve-ui"]) allowUI = YES;
            else if ([arg isEqualToString:@"--auto-map"]) { autoMap = YES; allowUI = YES; }
            else if ([arg isEqualToString:@"--auto-note"]) { autoNote = YES; allowUI = YES; }
            else if (!task) task = arg;
            else { fprintf(stderr, "Too many arguments\n"); return 2; }
        }
        if (!task.length) { fprintf(stderr, "Missing request\n"); return 2; }
        if ((autoMap && (!claude || !BBMapQuery(task))) ||
            (autoNote && !BBNoteText(task)) || (autoMap && autoNote)) return 2;
        return BBRun(task, claude, allowUI, autoMap, autoNote);
    }
}
