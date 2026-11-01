#import "BBQuickOverlay.h"
#import "AgentClient.h"
#import "AccessibilityManager.h"
#import "HIDManager.h"
#import <UIKit/UIKit.h>

@interface BBQuickOverlay () <UITextFieldDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextField *field;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic) NSUInteger dictationGeneration;
@end

@implementation BBQuickOverlay

+ (instancetype)shared {
    static BBQuickOverlay *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [BBQuickOverlay new]; });
    return instance;
}

- (UIWindowScene *)windowScene {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    return nil;
}

- (BOOL)show {
    if (!NSThread.isMainThread) return NO;
    if (self.window) { [self.field becomeFirstResponder]; return YES; }
    UIWindowScene *scene = [self windowScene];
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene] :
        [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    if (!window) return NO;
    window.frame = UIScreen.mainScreen.bounds;
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.clearColor;
    window.rootViewController = root;

    UIControl *backdrop = [UIControl new];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    backdrop.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.53];
    [backdrop addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:backdrop];

    UIView *panel = [UIView new];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = UIColor.secondarySystemBackgroundColor;
    panel.layer.cornerRadius = 26;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.shadowColor = UIColor.blackColor.CGColor;
    panel.layer.shadowOpacity = 0.25;
    panel.layer.shadowRadius = 22;
    [root.view addSubview:panel];

    UIView *accent = [UIView new];
    accent.translatesAutoresizingMaskIntoConstraints = NO;
    accent.backgroundColor = UIColor.systemIndigoColor;
    accent.layer.cornerRadius = 3;
    [panel addSubview:accent];
    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Ask BeanBao";
    title.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    title.textColor = UIColor.labelColor;
    [panel addSubview:title];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
    close.tintColor = UIColor.tertiaryLabelColor;
    [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
    close.accessibilityLabel = @"Close BeanBao quick input";
    [panel addSubview:close];

    self.field = [UITextField new];
    self.field.translatesAutoresizingMaskIntoConstraints = NO;
    self.field.placeholder = @"Say or type a request";
    self.field.font = [UIFont systemFontOfSize:18];
    self.field.backgroundColor = UIColor.tertiarySystemGroupedBackgroundColor;
    self.field.borderStyle = UITextBorderStyleRoundedRect;
    self.field.returnKeyType = UIReturnKeyGo;
    self.field.delegate = self;
    self.field.accessibilityLabel = @"BeanBao request";
    [panel addSubview:self.field];

    self.message = [UILabel new];
    self.message.translatesAutoresizingMaskIntoConstraints = NO;
    self.message.text = @"Review your request before running it.";
    self.message.textColor = UIColor.secondaryLabelColor;
    self.message.font = [UIFont systemFontOfSize:13];
    self.message.numberOfLines = 0;
    [panel addSubview:self.message];
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.runButton setTitle:@"Run" forState:UIControlStateNormal];
    [self.runButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    self.runButton.backgroundColor = UIColor.systemIndigoColor;
    self.runButton.layer.cornerRadius = 13;
    self.runButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [self.runButton addTarget:self action:@selector(run) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:self.runButton];

    [NSLayoutConstraint activateConstraints:@[
        [backdrop.leadingAnchor constraintEqualToAnchor:root.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:root.view.trailingAnchor],
        [backdrop.topAnchor constraintEqualToAnchor:root.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:root.view.bottomAnchor],
        [panel.leadingAnchor constraintEqualToAnchor:root.view.leadingAnchor constant:18],
        [panel.trailingAnchor constraintEqualToAnchor:root.view.trailingAnchor constant:-18],
        [panel.topAnchor constraintEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:74],
        [accent.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [accent.topAnchor constraintEqualToAnchor:panel.topAnchor constant:22],
        [accent.widthAnchor constraintEqualToConstant:38],
        [accent.heightAnchor constraintEqualToConstant:6],
        [title.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [title.topAnchor constraintEqualToAnchor:accent.bottomAnchor constant:14],
        [close.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-17],
        [close.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],
        [close.widthAnchor constraintEqualToConstant:36],
        [close.heightAnchor constraintEqualToConstant:36],
        [self.field.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [self.field.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20],
        [self.field.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:18],
        [self.field.heightAnchor constraintEqualToConstant:50],
        [self.message.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [self.message.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20],
        [self.message.topAnchor constraintEqualToAnchor:self.field.bottomAnchor constant:12],
        [self.runButton.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:20],
        [self.runButton.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-20],
        [self.runButton.topAnchor constraintEqualToAnchor:self.message.bottomAnchor constant:18],
        [self.runButton.heightAnchor constraintEqualToConstant:48],
        [self.runButton.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-20]
    ]];
    self.window = window;
    window.alpha = 0;
    [window makeKeyAndVisible];
    [UIView animateWithDuration:0.22 animations:^{ window.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ if (self.window == window) [self.field becomeFirstResponder]; });
    return YES;
}

- (BOOL)showAndStartDictation {
    if (![self show]) return NO;
    NSUInteger generation = ++self.dictationGeneration;
    self.message.text = @"Starting voice input…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.window || generation != self.dictationGeneration) return;
        [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:100
                                                                    visibleOnly:YES
                                                                  clickableOnly:NO
                                                                     completion:^(NSDictionary *payload, NSString *error) {
            (void)error;
            NSArray *elements = [payload[@"elements"] isKindOfClass:NSArray.class] ? payload[@"elements"] : @[];
            CGFloat screenHeight = UIScreen.mainScreen.bounds.size.height;
            NSDictionary *candidate = nil;
            CGFloat lowestY = 0;
            for (NSDictionary *element in elements) {
                if (![element isKindOfClass:NSDictionary.class] ||
                    ![element[@"text"] isEqualToString:@"Dictate"] ||
                    ![element[@"clickable"] boolValue]) continue;
                NSDictionary *tap = element[@"tap"];
                CGFloat x = [tap[@"x"] doubleValue], y = [tap[@"y"] doubleValue];
                if (x <= 0 || x >= UIScreen.mainScreen.bounds.size.width ||
                    y < screenHeight * 0.75 || y >= screenHeight || y <= lowestY) continue;
                candidate = tap;
                lowestY = y;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.window || generation != self.dictationGeneration) return;
                if (!candidate) {
                    self.message.text = @"Tap the keyboard microphone to dictate, or type your request.";
                    return;
                }
                [[IOSMCPHIDManager sharedInstance] tapAtPoint:CGPointMake([candidate[@"x"] doubleValue],
                                                                           [candidate[@"y"] doubleValue])
                    completion:^(BOOL success, NSString *failure) {
                        (void)failure;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (!self.window || generation != self.dictationGeneration) return;
                            self.message.text = success ? @"Listening… Tap Done on the keyboard, then Run." :
                                @"Tap the keyboard microphone to dictate, or type your request.";
                        });
                    }];
            });
        }];
    });
    return YES;
}

- (void)hide {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; }); return; }
    self.dictationGeneration++;
    [self.field resignFirstResponder];
    self.window.hidden = YES;
    self.window.rootViewController = nil;
    self.window = nil;
    self.field = nil;
    self.message = nil;
    self.runButton = nil;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    (void)textField;
    [self run];
    return NO;
}

- (void)run {
    NSString *task = [self.field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!task.length || task.length > 220) {
        self.message.text = @"Enter a request of up to 220 characters.";
        return;
    }
    [self hide]; // The Agent must observe the target app without this overlay.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"start", @"task": task});
        if (![reply[@"ok"] boolValue]) dispatch_async(dispatch_get_main_queue(), ^{
            if ([self show]) {
                self.field.text = task;
                self.message.text = [reply[@"error"] isKindOfClass:NSString.class] ?
                    reply[@"error"] : @"Could not start the task.";
            }
        });
    });
}

@end
