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

static const char *BBSocket = "/var/mobile/Library/Caches/BeanBao/bridge.sock";
static const char *BBToken = "/var/mobile/Library/Caches/BeanBao/bridge.token";
static const char *BBClaudeKey = "/var/mobile/Library/Application Support/BeanBao/claude.key";
static const char *BBLegacyClaudeKey = "/var/mobile/Library/Caches/BeanBao/claude.key";
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
extern int32_t BBRunHarnessMock(const char *task);
extern int32_t BBRunHarnessNote(const char *task);
extern int32_t BBRunHarnessMap(const char *task);
extern int32_t BBRunHarnessMapMock(const char *task);

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
    NSDictionary *targets = @{@"设置": @"com.apple.Preferences", @"备忘录": @"com.apple.mobilenotes",
                              @"地图": @"com.apple.Maps", @"通讯录": @"com.apple.MobileAddressBook"};
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
        if ([name isEqualToString:@"input_text"] && BBMapSearchInputReady(observation) &&
            !BBVisibleContains(observation, query) &&
            (uiSteps == 0 || (uiSteps == 1 && [uiHistory[0] isEqualToString:@"tap"]) ||
             (uiSteps == 2 && [uiHistory[0] isEqualToString:@"tap"] &&
              [uiHistory[1] isEqualToString:@"tap"])))
            return [action[@"text"] isKindOfClass:NSString.class] && [action[@"text"] isEqualToString:query];
        if ([name isEqualToString:@"press_key"] &&
            ((uiSteps == 0 && BBMapSearchInputReady(observation)) ||
             (uiSteps == 1 && [uiHistory[0] isEqualToString:@"input_text"]) ||
             (uiSteps == 2 && [uiHistory[0] isEqualToString:@"tap"] &&
              [uiHistory[1] isEqualToString:@"input_text"]) ||
             (uiSteps == 3 && [uiHistory[0] isEqualToString:@"tap"] &&
              [uiHistory[1] isEqualToString:@"tap"] &&
              [uiHistory[2] isEqualToString:@"input_text"])))
            return [action[@"key"] isKindOfClass:NSString.class] && [action[@"key"] isEqualToString:@"enter"] &&
                BBVisibleContains(observation, [query substringToIndex:MIN((NSUInteger)12, query.length)]);
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
    fprintf(stdout, "待执行：%s\n输入 yes 执行这一步：", [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
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
    if (priorUIAction && action[@"error"]) {
        for (NSUInteger retry = 0; retry < 6; retry++) {
            usleep(350000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.mobilenotes"])
                break;
            observation = settled;
            if (BBHasSecret(observation[@"ui"]) || BBHasSecret(observation[@"ocr"])) continue;
            action = BBFixedNoteAction(task, observation, history);
            if (!action[@"error"]) break;
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
        if (BBVisibleContains(observation, query))
            return @{@"action": @"press_key", @"key": @"enter"};
        if ([history.lastObject[@"action"] isEqualToString:@"input_text"])
            return BBError(@"local_state");
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
        @{@"action": @"done"} : BBMapFixedSuggestionAction(observation, query));
    if (!fixedAction && [history.lastObject[@"action"] isEqualToString:@"input_text"] &&
        !BBVisibleContains(observation, query)) {
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
            if (BBVisibleContains(observation, query)) {
                fixedAction = BBMapFixedSuggestionAction(observation, query);
                break;
            }
        }
        if (!fixedAction && !BBVisibleContains(observation, query))
            return @{@"ok": @NO, @"error": @"input_unverified"};
    }
    if (!fixedAction && [history.lastObject[@"action"] isEqualToString:@"input_text"] &&
        [observation[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] &&
        BBVisibleContains(observation, query)) {
        for (NSUInteger retry = 0; retry < 8; retry++) {
            usleep(500000);
            NSDictionary *settled = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @YES});
            if (![settled[@"ok"] boolValue] || !BBUnlockedObservation(settled) ||
                ![settled[@"frontmost_app"][@"bundleId"] isEqualToString:@"com.apple.Maps"] ||
                BBHasSecret(settled[@"ui"]) || BBHasSecret(settled[@"ocr"])) break;
            observation = settled;
            fixedAction = BBMapFixedSuggestionAction(observation, query);
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
            @{@"action": @"done"} : BBMapFixedSuggestionAction(observation, query);
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
    BOOL suggestionTap = [name isEqualToString:@"tap"] &&
        BBMapSuggestionTapAllowed(observation, query,
                                  [action[@"x"] doubleValue], [action[@"y"] doubleValue]);
    NSDictionary *fresh = bridge(@{@"op": @"observe", @"ui": @YES, @"ocr": @(suggestionTap)});
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

static char *BBMapStepEncoded(const char *taskText, const char *historyJSON, BOOL useClaude) {
    @autoreleasepool {
        if (!taskText || !historyJSON) return NULL;
        NSString *task = [NSString stringWithUTF8String:taskText];
        NSData *historyData = [[NSString stringWithUTF8String:historyJSON] dataUsingEncoding:NSUTF8StringEncoding];
        if (!task || !historyData) return NULL;
        id history = [NSJSONSerialization JSONObjectWithData:historyData options:0 error:nil];
        if (![history isKindOfClass:NSArray.class]) return NULL;
        for (id item in history) if (![item isKindOfClass:NSDictionary.class]) return NULL;
        NSString *key = useClaude ? (BBReadSecret(BBClaudeKey, 0) ?:
            BBReadSecret(BBLegacyClaudeKey, 0)) : nil;
        NSDictionary *result = (useClaude && (![key hasPrefix:@"sk-ant-"] || key.length < 24)) ?
            @{@"ok": @NO, @"error": @"key"} :
            BBMapStep(task, history,
                ^NSDictionary *(NSDictionary *request) { return BBBridge(request); },
                ^NSDictionary *(NSString *command, NSDictionary *observation, NSArray *prior) {
                    return useClaude ? BBClaudeAction(command, observation, prior, key) :
                        BBFixedMapAction(command, observation, prior);
                }, useClaude);
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
    return BBMapStepEncoded(taskText, historyJSON, YES);
}

char *BBMapMockStepJSON(const char *taskText, const char *historyJSON) {
    return BBMapStepEncoded(taskText, historyJSON, NO);
}

static int BBRun(NSString *task, BOOL claude, BOOL allowUI, BOOL autoMap, BOOL autoNote) {
    if (claude && [task isEqualToString:@"打开通讯录"]) {
        fprintf(stderr, "打开通讯录请使用模拟模型\n");
        return 1;
    }
    NSString *auditApp = BBRequestedApp(task);
    NSString *key = claude && !autoNote ? (BBReadSecret(BBClaudeKey, 0) ?: BBReadSecret(BBLegacyClaudeKey, 0)) : nil;
    if (claude && !autoNote && (![key hasPrefix:@"sk-ant-"] || key.length < 24)) { fprintf(stderr, "Claude Key 未配置或权限不安全\n"); return 1; }
    if ((claude || autoNote) && BBHasSecret(task)) { fprintf(stderr, "任务文字包含疑似密钥，已停止模型请求\n"); return 1; }
    @try {
    NSMutableArray *history = [NSMutableArray array];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:300];
    for (int step = 0; step < 20 && [deadline timeIntervalSinceNow] > 0; step++) {
        NSDictionary *lease = BBBridge(@{@"op": @"wake_lease", @"mode": @"renew"});
        if (![lease[@"ok"] boolValue]) {
            NSString *leaseError = [lease[@"error"] isKindOfClass:NSString.class] ? lease[@"error"] : @"";
            if ([leaseError containsString:@"locked"] ||
                [leaseError containsString:@"screen is off"])
                fprintf(stderr, "设备已锁定或屏幕关闭，停止模型请求\n");
            else fprintf(stderr, "防自动锁屏不可用，已停止任务\n");
            return 1;
        }
        NSDictionary *observation = BBBridge(@{@"op": @"observe", @"ui": @YES,
            @"ocr": @(claude || autoNote), @"screenshot": @(claude && !autoNote)});
        if (![observation[@"ok"] boolValue]) { fprintf(stderr, "观察失败\n"); return 1; }
        if (!BBUnlockedObservation(observation)) { fprintf(stderr, "设备已锁定或屏幕关闭，停止模型请求\n"); return 1; }
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
            fprintf(stderr, "界面包含疑似密钥，已停止模型请求\n"); return 1;
        }
        NSDictionary *fixedMapAction = fixedMapLaunch ?: (autoMap ?
            BBMapFixedSuggestionAction(observation, BBMapQuery(task)) : nil);
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
                fixedMapAction = BBMapFixedSuggestionAction(observation, BBMapQuery(task));
                if (fixedMapAction) break;
            }
        }
        NSDictionary *action = autoNote ? fixedNoteAction :
            (fixedMapAction ?: (claude ? BBClaudeAction(task, observation, history, key) : BBMockAction(task, observation, history.count)));
        if (action[@"error"]) {
            fprintf(stderr, autoNote ? "备忘录界面状态不符合安全条件\n" : "模型请求或输出失败\n");
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
            fprintf(stderr, "模型动作被策略拒绝：步骤 %d，类型 %s\n", step + 1,
                    [kind isKindOfClass:NSString.class] &&
                    [@[@"launch_app", @"tap", @"swipe", @"input_text", @"press_key", @"done"] containsObject:kind]
                        ? kind.UTF8String : "unknown");
            return 1;
        }
        NSString *name = action[@"action"];
        if ([name isEqualToString:@"done"]) {
            BBAudit(@"step", auditApp, @"done", @"ok");
            puts([action[@"summary"] isKindOfClass:NSString.class] ? [action[@"summary"] UTF8String] : "完成");
            return 0;
        }
        if (![name isEqualToString:@"launch_app"] && !autoMap && !autoNote && !BBApprove(action)) { fprintf(stderr, "用户未批准动作\n"); return 1; }
        BOOL suggestionTap = autoMap && [name isEqualToString:@"tap"] &&
            BBMapSuggestionTapAllowed(observation, BBMapQuery(task),
                                      [action[@"x"] doubleValue], [action[@"y"] doubleValue]);
        NSDictionary *fresh = BBBridge(@{@"op": @"observe", @"ui": @YES,
            @"ocr": @(suggestionTap || autoNote)});
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
            fprintf(stderr, "界面复核未通过：步骤 %d，UI=%d，App=%d，策略=%d，时效=%d\n",
                    step + 1, sameUI, sameApp, allowed, recent);
            return 1;
        }
        NSMutableDictionary *request = [action mutableCopy];
        request[@"op"] = @"act"; request[@"observation_id"] = fresh[@"observation_id"];
        NSDictionary *result = BBBridge(request);
        if (![result[@"ok"] boolValue]) {
            BBAudit(@"step", auditApp, name, @"failed");
            fprintf(stderr, "动作执行失败\n"); return 1;
        }
        BBAudit(@"step", auditApp, name, @"ok");
        [history addObject:action];
    }
    fprintf(stderr, "任务超过时间或步数上限\n"); return 1;
    } @finally {
        BBReleaseWakeLease();
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && !strcmp(argv[1], "--serve")) return BBServe();
        if (argc == 3 && !strcmp(argv[1], "--harness-mock")) return BBRunHarnessMock(argv[2]);
        if (argc == 3 && !strcmp(argv[1], "--harness-note")) return BBRunHarnessNote(argv[2]);
        if (argc == 3 && !strcmp(argv[1], "--harness-map")) return BBRunHarnessMap(argv[2]);
        if (argc == 3 && !strcmp(argv[1], "--harness-map-mock")) return BBRunHarnessMapMock(argv[2]);
        if (argc < 2) { fprintf(stderr, "用法：beanbaod [--claude] [--approve-ui] '任务文字'\n"); return 2; }
        BOOL claude = NO, allowUI = NO, autoMap = NO, autoNote = NO;
        NSString *task = nil;
        for (int i = 1; i < argc; i++) {
            NSString *arg = [NSString stringWithUTF8String:argv[i]];
            if ([arg isEqualToString:@"--claude"]) claude = YES;
            else if ([arg isEqualToString:@"--approve-ui"]) allowUI = YES;
            else if ([arg isEqualToString:@"--auto-map"]) { autoMap = YES; allowUI = YES; }
            else if ([arg isEqualToString:@"--auto-note"]) { autoNote = YES; allowUI = YES; }
            else if (!task) task = arg;
            else { fprintf(stderr, "参数过多\n"); return 2; }
        }
        if (!task.length) { fprintf(stderr, "缺少任务\n"); return 2; }
        if ((autoMap && (!claude || !BBMapQuery(task))) ||
            (autoNote && !BBNoteText(task)) || (autoMap && autoNote)) return 2;
        return BBRun(task, claude, allowUI, autoMap, autoNote);
    }
}
