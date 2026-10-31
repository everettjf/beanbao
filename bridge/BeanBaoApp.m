#import "BeanBaoApp.h"
#import "AccessibilityManager.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

BOOL BBIsAllowedApp(NSString *bundleID) {
    return [@[@"com.apple.Preferences", @"com.apple.mobilenotes", @"com.apple.Maps",
              @"com.apple.MobileAddressBook", @"dev.beanbao.app"] containsObject:bundleID ?: @""];
}

NSDictionary *BBFrontmostApp(void) {
    NSDictionary *info = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    return [info isKindOfClass:[NSDictionary class]] ? info : @{};
}

BOOL BBLaunchAllowedApp(NSString *bundleID, NSString **error) {
    if (![@[@"com.apple.Preferences", @"com.apple.mobilenotes", @"com.apple.Maps",
            @"com.apple.MobileAddressBook"] containsObject:bundleID ?: @""]) {
        if (error) *error = @"App is outside the BeanBao allowlist";
        return NO;
    }
    Class cls = objc_getClass("LSApplicationWorkspace");
    SEL workspaceSel = @selector(defaultWorkspace);
    SEL openSel = @selector(openApplicationWithBundleID:);
    if (!cls || ![cls respondsToSelector:workspaceSel]) {
        if (error) *error = @"LaunchServices unavailable";
        return NO;
    }
    @try {
        id workspace = ((id (*)(id, SEL))objc_msgSend)((id)cls, workspaceSel);
        if (!workspace || ![workspace respondsToSelector:openSel] ||
            !((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, bundleID)) {
            if (error) *error = @"LaunchServices rejected launch";
            return NO;
        }
        for (NSUInteger i = 0; i < 25; i++) {
            if ([BBFrontmostApp()[@"bundleId"] isEqualToString:bundleID]) return YES;
            usleep(200000);
        }
        if (error) *error = @"Launch was not confirmed in foreground";
    } @catch (NSException *exception) {
        if (error) *error = exception.reason ?: @"Launch exception";
    }
    return NO;
}

void BBOpenBeanBaoApp(void) {
    Class cls = objc_getClass("LSApplicationWorkspace");
    SEL workspaceSel = @selector(defaultWorkspace);
    SEL openSel = @selector(openApplicationWithBundleID:);
    if (!cls || ![cls respondsToSelector:workspaceSel]) return;
    @try {
        id workspace = ((id (*)(id, SEL))objc_msgSend)((id)cls, workspaceSel);
        if ([workspace respondsToSelector:openSel])
            ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, @"dev.beanbao.app");
    } @catch (__unused NSException *exception) {}
}
