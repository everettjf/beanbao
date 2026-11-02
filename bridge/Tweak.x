#import <Foundation/Foundation.h>
#import "BeanBaoBridge.h"
#import "BeanBaoApp.h"
#import "BBQuickOverlay.h"
#import "ScreenManager.h"
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <objc/runtime.h>

static const char *BBHotkeyFile = "/var/mobile/Library/Caches/BeanBao/hotkey.enabled";

static BOOL BBHotkeyEnabled(void) {
    int fd = open(BBHotkeyFile, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return NO;
    struct stat info = {0};
    char value = 0;
    BOOL enabled = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == 501 &&
        !(info.st_mode & 077) && info.st_size == 1 && read(fd, &value, 1) == 1 && value == '1';
    close(fd);
    return enabled;
}

static void BBVolumeDownReleased(void) {
    static NSUInteger count = 0;
    static NSTimeInterval lastRelease = 0;
    static NSTimeInterval lastTrigger = 0;
    if (!BBHotkeyEnabled()) { count = 0; return; }
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - lastTrigger < 3.0) { count = 0; return; }
    count = now - lastRelease <= 0.65 ? count + 1 : 1;
    lastRelease = now;
    if (count < 3) return;
    count = 0;
    lastTrigger = now;
    // Let SpringBoard finish the volume-button event and dismiss its HUD before
    // asking LaunchServices to foreground the microphone owner app.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSDictionary *state = [[ScreenManager sharedInstance] deviceInteractionState];
        if (![state[@"locked_known"] boolValue] || [state[@"locked"] boolValue] ||
            ![state[@"screen_on_known"] boolValue] || ![state[@"screen_on"] boolValue]) return;
        NSString *bundleID = BBFrontmostApp()[@"bundleId"];
        if ([bundleID isEqualToString:@"dev.beanbao.app"]) return;
        [[BBQuickOverlay shared] beginVoiceFromBundle:bundleID];
    });
}

%hook SBVolumeHardwareButtonActions
- (void)volumeDecreasePressUp {
    %orig;
    BBVolumeDownReleased();
}
%end

%ctor {
    Class actions = objc_getClass("SBVolumeHardwareButtonActions");
    if (actions && class_getInstanceMethod(actions, @selector(volumeDecreasePressUp))) %init;
}

__attribute__((constructor)) static void BBStart(void) {
    if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) return;
    // Delay startup until SpringBoard has entered its normal run loop.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ [[BeanBaoBridge shared] start]; });
}
