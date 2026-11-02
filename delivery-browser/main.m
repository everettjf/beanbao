#import <UIKit/UIKit.h>
#import "DeliveryBrowserViewController.h"
#import "AgentClient.h"

@interface BBDeliveryAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation BBDeliveryAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc]
        initWithRootViewController:[BBDeliveryBrowserViewController new]];
    [self.window makeKeyAndVisible];
    return YES;
}

- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    (void)application; (void)options;
    if (![url.scheme.lowercaseString isEqualToString:@"beanbaodelivery"] ||
        ![url.host.lowercaseString isEqualToString:@"open"]) return NO;
    NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *token = nil;
    for (NSURLQueryItem *item in parts.queryItems)
        if ([item.name isEqualToString:@"token"]) token = item.value;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:
        @"0123456789abcdef"].invertedSet;
    if (token.length != 64 || [token rangeOfCharacterFromSet:invalid].location != NSNotFound)
        return NO;
    BBSetDeliveryPairingToken(token);
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BBDeliveryAppDelegate.class)); }
}
