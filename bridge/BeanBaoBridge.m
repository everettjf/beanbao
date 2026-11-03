#import "BeanBaoBridge.h"
#import "BBObservationClock.h"
#import "BeanBaoApp.h"
#import "BBQuickOverlay.h"
#import "ScreenManager.h"
#import "AccessibilityManager.h"
#import "VisionOCREngine.h"
#import "HIDManager.h"
#import "TextInputManager.h"
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#include <string.h>

// SpringBoard and the no-sandbox CLI share the host namespace. The ordinary
// RootHide SSH shell sees this directory via /rootfs/private/var/mobile.
static NSString *BBDirectory(void) { return @"/var/mobile/Library/Caches/BeanBao"; }
static NSString *BBSocket(void) { return [BBDirectory() stringByAppendingPathComponent:@"bridge.sock"]; }
static NSString *BBTokenFile(void) { return [BBDirectory() stringByAppendingPathComponent:@"bridge.token"]; }
static const size_t BBMaxRequest = 65536;
static const size_t BBMaxResponse = 8 * 1024 * 1024;
static const NSTimeInterval BBWakeLeaseSeconds = 90;

@interface BeanBaoBridge ()
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *observationID;
@property (nonatomic, copy) NSString *observationApp;
@property (nonatomic) NSTimeInterval observationTime;
@property (nonatomic) NSTimeInterval observationUptime;
@property (nonatomic) int listenFD;
@property (nonatomic) BOOL wakeLeaseActive;
@property (nonatomic) BOOL idleTimerBeforeLease;
@property (nonatomic) NSTimeInterval wakeLeaseExpiry;
@property (nonatomic, strong) NSTimer *wakeLeaseTimer;
@end

@implementation BeanBaoBridge

+ (instancetype)shared {
    static BeanBaoBridge *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [BeanBaoBridge new]; });
    return instance;
}

static BOOL BBWriteAll(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    while (length) {
        ssize_t sent = write(fd, cursor, length);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return NO;
        cursor += sent;
        length -= (size_t)sent;
    }
    return YES;
}

static NSDictionary *BBError(NSString *message) {
    return @{@"ok": @NO, @"error": message ?: @"Unknown error"};
}

static BOOL BBValidNumber(id value, double *number) {
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double parsed = [value doubleValue];
    if (!isfinite(parsed)) return NO;
    if (number) *number = parsed;
    return YES;
}

static NSString *BBTokenFromFile(void) {
    NSString *existing = [NSString stringWithContentsOfFile:BBTokenFile() encoding:NSUTF8StringEncoding error:nil];
    if (existing.length == 64) return existing;
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) return nil;
    NSMutableString *hex = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i < sizeof(bytes); i++) [hex appendFormat:@"%02x", bytes[i]];
    int fd = open(BBTokenFile().fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) {
        if (errno == EEXIST) return [NSString stringWithContentsOfFile:BBTokenFile() encoding:NSUTF8StringEncoding error:nil];
        return nil;
    }
    BOOL saved = BBWriteAll(fd, hex.UTF8String, hex.length);
    close(fd);
    if (!saved) { unlink(BBTokenFile().fileSystemRepresentation); return nil; }
    return hex;
}

- (void)start {
    if (self.listenFD > 0) return;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:BBDirectory()
                                   withIntermediateDirectories:YES
                                                    attributes:@{NSFilePosixPermissions: @0700}
                                                         error:nil]) return;
    chmod(BBDirectory().fileSystemRepresentation, 0700);
    self.token = BBTokenFromFile();
    if (self.token.length != 64) return;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return;
    int noSigpipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, sizeof(noSigpipe));
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(BBSocket().fileSystemRepresentation) >= sizeof(address.sun_path)) {
        close(fd);
        return;
    }
    strlcpy(address.sun_path, BBSocket().fileSystemRepresentation, sizeof(address.sun_path));
    unlink(BBSocket().fileSystemRepresentation);
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 2) != 0) {
        close(fd);
        return;
    }
    chmod(BBSocket().fileSystemRepresentation, 0600);
    self.listenFD = fd;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (self.listenFD == fd) {
            int client = accept(fd, NULL, NULL);
            if (client < 0) { if (errno == EINTR) continue; break; }
            [self serveClient:client];
            close(client);
        }
    });
}

- (BOOL)unlocked {
    NSDictionary *state = [[ScreenManager sharedInstance] deviceInteractionState];
    return [state[@"locked_known"] boolValue] && ![state[@"locked"] boolValue] &&
           [state[@"screen_on_known"] boolValue] && [state[@"screen_on"] boolValue];
}

- (void)endWakeLeaseOnMain {
    if (!self.wakeLeaseActive) return;
    self.wakeLeaseActive = NO;
    self.wakeLeaseExpiry = 0;
    [self.wakeLeaseTimer invalidate];
    self.wakeLeaseTimer = nil;
    UIApplication.sharedApplication.idleTimerDisabled = self.idleTimerBeforeLease;
}

- (void)checkWakeLeaseOnMain {
    if (!self.wakeLeaseActive) return;
    if (NSProcessInfo.processInfo.systemUptime >= self.wakeLeaseExpiry || ![self unlocked]) {
        [self endWakeLeaseOnMain];
        return;
    }
    // SpringBoard may update its own idle timer state while an app changes.
    UIApplication.sharedApplication.idleTimerDisabled = YES;
}

- (NSDictionary *)wakeLeaseOnMain:(NSString *)mode {
    if ([mode isEqualToString:@"release"]) {
        [self endWakeLeaseOnMain];
        return @{@"ok": @YES, @"active": @NO};
    }
    if (![mode isEqualToString:@"renew"]) return BBError(@"Invalid wake lease mode");
    if (![self unlocked]) {
        [self endWakeLeaseOnMain];
        return BBError(@"Device is locked, screen is off, or state is unknown");
    }
    UIApplication *application = UIApplication.sharedApplication;
    if (!application) {
        [self endWakeLeaseOnMain];
        return BBError(@"SpringBoard application unavailable");
    }
    if (!self.wakeLeaseActive) self.idleTimerBeforeLease = application.idleTimerDisabled;
    application.idleTimerDisabled = YES;
    if (!application.idleTimerDisabled) {
        [self endWakeLeaseOnMain];
        return BBError(@"Idle timer could not be disabled");
    }
    self.wakeLeaseActive = YES;
    self.wakeLeaseExpiry = NSProcessInfo.processInfo.systemUptime + BBWakeLeaseSeconds;
    if (!self.wakeLeaseTimer) {
        self.wakeLeaseTimer = [NSTimer timerWithTimeInterval:1 target:self
            selector:@selector(checkWakeLeaseOnMain) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.wakeLeaseTimer forMode:NSRunLoopCommonModes];
    }
    return @{@"ok": @YES, @"active": @YES, @"lease_seconds": @(BBWakeLeaseSeconds)};
}

- (NSDictionary *)wakeLease:(NSDictionary *)request {
    NSString *mode = request[@"mode"];
    if (![mode isKindOfClass:NSString.class] ||
        ![@[@"renew", @"release"] containsObject:mode]) return BBError(@"Invalid wake lease mode");
    __block NSDictionary *result = nil;
    if (NSThread.isMainThread) result = [self wakeLeaseOnMain:mode];
    else dispatch_sync(dispatch_get_main_queue(), ^{ result = [self wakeLeaseOnMain:mode]; });
    return result;
}

- (NSDictionary *)quickOverlay:(NSDictionary *)request {
    NSString *mode = request[@"mode"];
    if (![mode isKindOfClass:NSString.class] || ![@[@"show", @"show_voice", @"hide"] containsObject:mode])
        return BBError(@"Invalid quick overlay mode");
    if (![mode isEqualToString:@"hide"] && ![self unlocked])
        return BBError(@"Device is locked, screen is off, or state is unknown");
    __block BOOL shown = YES;
    void (^update)(void) = ^{
        if ([mode isEqualToString:@"show"]) shown = [[BBQuickOverlay shared] show];
        else if ([mode isEqualToString:@"show_voice"])
            shown = [[BBQuickOverlay shared] beginVoiceFromBundle:BBFrontmostApp()[@"bundleId"]];
        else [[BBQuickOverlay shared] hide];
    };
    if (NSThread.isMainThread) update();
    else dispatch_sync(dispatch_get_main_queue(), update);
    return shown ? @{@"ok": @YES} : BBError(@"Quick overlay could not open");
}

- (NSDictionary *)observe:(NSDictionary *)request {
    NSDictionary *state = [[ScreenManager sharedInstance] deviceInteractionState] ?: @{};
    NSDictionary *frontmost = BBFrontmostApp();
    NSString *app = [frontmost[@"bundleId"] isKindOfClass:[NSString class]] ? frontmost[@"bundleId"] : @"";
    NSTimeInterval observationUptime = BBObservationClockSeconds();
    if (!isfinite(observationUptime)) return BBError(@"Observation clock unavailable");
    self.observationID = [NSUUID UUID].UUIDString;
    self.observationApp = app;
    self.observationTime = NSDate.date.timeIntervalSince1970;
    self.observationUptime = observationUptime;
    NSMutableDictionary *payload = [@{@"ok": @YES, @"observation_id": self.observationID,
                                     @"timestamp": @(self.observationTime), @"device_state": state,
                                     @"frontmost_app": frontmost,
                                     @"screen": [[ScreenManager sharedInstance] screenInfo] ?: @{}} mutableCopy];
    BOOL canReadContent = [self unlocked] && BBIsAllowedApp(app);
    if ([request[@"ui"] boolValue] && canReadContent) {
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSDictionary *ui = nil;
        __block NSString *error = nil;
        [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:80
                                                                        visibleOnly:YES
                                                                      clickableOnly:NO
                                                                         completion:^(NSDictionary *result, NSString *failure) {
            ui = result;
            error = failure;
            dispatch_semaphore_signal(done);
        }];
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0) {
            if (ui) payload[@"ui"] = ui;
            if (error) payload[@"ui_error"] = error;
        } else payload[@"ui_error"] = @"UI query timed out";
    }
    if ([request[@"ocr"] boolValue] && canReadContent) {
        NSString *error = nil;
        NSDictionary *ocr = [[VisionOCREngine sharedInstance] recognizeTextWithLanguages:@[@"zh-Hans", @"en-US"]
                                                                         minConfidence:0.3 region:nil fast:NO error:&error];
        if (ocr) payload[@"ocr"] = ocr;
        if (error) payload[@"ocr_error"] = error;
    }
    if ([request[@"screenshot"] boolValue] && canReadContent) {
        NSDictionary *shot = [[ScreenManager sharedInstance] takeScreenshotPayload];
        if (shot) payload[@"screenshot"] = shot;
    }
    return payload;
}

- (NSDictionary *)perform:(NSDictionary *)request {
    if (![self unlocked]) return BBError(@"Device is locked, screen is off, or state is unknown");
    NSString *observed = request[@"observation_id"];
    if (![observed isKindOfClass:[NSString class]] || ![observed isEqualToString:self.observationID] ||
        !BBObservationIsFresh(self.observationUptime, BBObservationClockSeconds()))
        return BBError(@"Observation is missing or stale");
    NSString *currentApp = BBFrontmostApp()[@"bundleId"];
    if (![(currentApp ?: @"") isEqualToString:self.observationApp ?: @""]) return BBError(@"Foreground app changed");
    NSString *action = request[@"action"];
    if (![action isKindOfClass:[NSString class]]) return BBError(@"Missing action");
    __block NSString *error = nil;
    __block BOOL success = NO;
    if ([action isEqualToString:@"launch_app"]) {
        success = BBLaunchAllowedApp(request[@"bundle_id"], &error);
    } else {
        if (!BBIsAllowedApp(currentApp)) return BBError(@"Foreground app is outside the allowlist");
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        void (^completion)(BOOL, NSString *) = ^(BOOL ok, NSString *failure) {
            success = ok; error = failure; dispatch_semaphore_signal(done);
        };
        NSDictionary *screen = [[ScreenManager sharedInstance] screenInfo];
        double width = [screen[@"width"] doubleValue], height = [screen[@"height"] doubleValue];
        if ([action isEqualToString:@"tap"]) {
            double x, y;
            if (!BBValidNumber(request[@"x"], &x) || !BBValidNumber(request[@"y"], &y) ||
                x < 0 || y < 0 || x >= width || y >= height) return BBError(@"Tap point outside screen");
            [[IOSMCPHIDManager sharedInstance] tapAtPoint:CGPointMake(x, y) completion:completion];
        } else if ([action isEqualToString:@"swipe"]) {
            double x1, y1, x2, y2;
            if (!BBValidNumber(request[@"x1"], &x1) || !BBValidNumber(request[@"y1"], &y1) ||
                !BBValidNumber(request[@"x2"], &x2) || !BBValidNumber(request[@"y2"], &y2) ||
                x1 < 0 || x1 >= width || x2 < 0 || x2 >= width ||
                y1 < 0 || y1 >= height || y2 < 0 || y2 >= height) return BBError(@"Swipe point outside screen");
            [[IOSMCPHIDManager sharedInstance] swipeFromPoint:CGPointMake(x1, y1) toPoint:CGPointMake(x2, y2)
                                                       duration:350 steps:12 completion:completion];
        } else if ([action isEqualToString:@"input_text"]) {
            NSString *value = request[@"text"];
            if (![value isKindOfClass:[NSString class]] || !value.length || value.length > 200)
                return BBError(@"Text must contain 1–200 characters");
            [[TextInputManager sharedInstance] inputText:value completion:completion];
        } else if ([action isEqualToString:@"press_key"]) {
            NSString *key = request[@"key"];
            if (![@[@"enter", @"delete", @"backspace", @"space"] containsObject:key ?: @""])
                return BBError(@"Key is outside the allowlist");
            [[TextInputManager sharedInstance] pressKey:key completion:completion];
        } else return BBError(@"Unknown action");
        if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) != 0)
            return BBError(@"Action timed out");
    }
    self.observationID = nil; // One observation authorizes at most one action.
    return success ? @{@"ok": @YES} : BBError(error ?: @"Action failed");
}

- (void)serveClient:(int)client {
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (getpeereid(client, &uid, &gid) != 0 || uid != 501) return;
    struct timeval timeout = {.tv_sec = 12, .tv_usec = 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    NSMutableData *data = [NSMutableData data];
    uint8_t byte;
    while (data.length < BBMaxRequest) {
        ssize_t count = read(client, &byte, 1);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return;
        if (byte == '\n') break;
        [data appendBytes:&byte length:1];
    }
    if (data.length >= BBMaxRequest) return;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary *request = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    NSDictionary *response;
    @try {
        if (!request) response = BBError(@"Invalid JSON object");
        else if (![request[@"token"] isKindOfClass:[NSString class]] || ![request[@"token"] isEqualToString:self.token])
            response = BBError(@"Unauthorized");
        else if ([request[@"op"] isEqualToString:@"observe"]) response = [self observe:request];
        else if ([request[@"op"] isEqualToString:@"act"]) response = [self perform:request];
        else if ([request[@"op"] isEqualToString:@"wake_lease"]) response = [self wakeLease:request];
        else if ([request[@"op"] isEqualToString:@"quick_overlay"]) response = [self quickOverlay:request];
        else response = BBError(@"Unknown operation");
    } @catch (NSException *exception) {
        response = BBError([NSString stringWithFormat:@"Bridge operation failed: %@", exception.name]);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    if (!json || json.length > BBMaxResponse) json = [NSJSONSerialization dataWithJSONObject:BBError(@"Response too large") options:0 error:nil];
    BBWriteAll(client, json.bytes, json.length);
    BBWriteAll(client, "\n", 1);
}

@end
