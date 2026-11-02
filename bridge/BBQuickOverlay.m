#import "BBQuickOverlay.h"
#import "AgentClient.h"
#import "BeanBaoApp.h"
#import "VoiceIPC.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface BBQuickOverlay () <UITextFieldDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UITextField *field;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, copy) NSString *voiceSession;
@property(nonatomic, copy) NSString *returnBundle;
@property(nonatomic) BOOL voiceReady;
@property(nonatomic) NSUInteger voiceGeneration;
@property(nonatomic) NSTimeInterval voiceDeadline;
@property(nonatomic) NSTimeInterval voiceReadyDeadline;
@end

static dispatch_queue_t BBAppLaunchQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("dev.beanbao.quick-overlay.launch", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

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

- (BOOL)showFocused:(BOOL)focus {
    if (!NSThread.isMainThread) return NO;
    if (self.window) { if (focus) [self.field becomeFirstResponder]; return YES; }
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
    self.field.placeholder = @"Type a request";
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
        [panel.topAnchor constraintGreaterThanOrEqualToAnchor:root.view.safeAreaLayoutGuide.topAnchor constant:12],
        [panel.bottomAnchor constraintEqualToAnchor:root.view.keyboardLayoutGuide.topAnchor constant:-18],
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
    if (focus) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ if (self.window == window) [self.field becomeFirstResponder]; });
    return YES;
}

- (BOOL)show { return [self showFocused:YES]; }

- (void)restorePreviousApp {
    NSString *bundleID = [self.returnBundle copy];
    if (!bundleID.length || [bundleID isEqualToString:@"com.apple.springboard"] ||
        [bundleID isEqualToString:@"dev.beanbao.app"]) return;
    dispatch_async(BBAppLaunchQueue(), ^{
        Class cls = objc_getClass("LSApplicationWorkspace");
        SEL workspaceSel = @selector(defaultWorkspace);
        SEL openSel = @selector(openApplicationWithBundleID:);
        if (!cls || ![cls respondsToSelector:workspaceSel]) return;
        @try {
            id workspace = ((id (*)(id, SEL))objc_msgSend)((id)cls, workspaceSel);
            if ([workspace respondsToSelector:openSel])
                ((BOOL (*)(id, SEL, NSString *))objc_msgSend)(workspace, openSel, bundleID);
        } @catch (__unused NSException *exception) {}
    });
}

- (BOOL)beginVoiceFromBundle:(NSString *)bundleID {
    if (!NSThread.isMainThread || self.window || self.voiceSession ||
        ![bundleID isKindOfClass:NSString.class] ||
        !bundleID.length || [bundleID isEqualToString:@"com.apple.springboard"] ||
        [bundleID isEqualToString:@"dev.beanbao.app"] || ![self showFocused:NO]) return NO;
    NSString *session = NSUUID.UUID.UUIDString;
    BBVoiceRemove(@"start"); BBVoiceRemove(@"ready");
    BBVoiceRemove(@"stop"); BBVoiceRemove(@"result"); BBVoiceRemove(@"cancel");
    if (!BBVoiceWrite(@"start", @{@"session": session,
                                  @"created": @(NSDate.date.timeIntervalSince1970)})) {
        self.message.text = @"Could not prepare voice input. You can type instead.";
        return NO;
    }
    self.voiceSession = session;
    self.returnBundle = bundleID;
    self.voiceReady = NO;
    self.voiceReadyDeadline = NSProcessInfo.processInfo.systemUptime + 25;
    self.voiceDeadline = NSProcessInfo.processInfo.systemUptime + 90;
    NSUInteger generation = ++self.voiceGeneration;
    self.message.text = @"Starting microphone…";
    [self.runButton setTitle:@"Stop recording" forState:UIControlStateNormal];
    dispatch_async(BBAppLaunchQueue(), ^{ BBOpenBeanBaoApp(); });
    [self pollVoiceSession:generation];
    return YES;
}

- (void)pollVoiceSession:(NSUInteger)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.window || !self.voiceSession || generation != self.voiceGeneration) return;
        NSDictionary *ready = BBVoiceRead(@"ready");
        if (!self.voiceReady && [ready[@"session"] isEqualToString:self.voiceSession]) {
            self.voiceReady = YES;
            self.message.text = @"Listening… Speak now.";
            [self restorePreviousApp];
        }
        NSDictionary *result = BBVoiceRead(@"result");
        if ([result[@"session"] isEqualToString:self.voiceSession]) {
            if (!self.voiceReady) [self restorePreviousApp];
            NSString *text = [result[@"text"] isKindOfClass:NSString.class] ? result[@"text"] : nil;
            self.field.text = text ?: @"";
            self.message.text = text.length ? @"Review the transcript, then tap Run." :
                @"No speech recognized. You can type your request.";
            self.voiceSession = nil;
            self.returnBundle = nil;
            BBVoiceRemove(@"start"); BBVoiceRemove(@"ready");
            BBVoiceRemove(@"stop"); BBVoiceRemove(@"result"); BBVoiceRemove(@"cancel");
            [self.runButton setTitle:@"Run" forState:UIControlStateNormal];
            self.runButton.enabled = YES;
            [self.field becomeFirstResponder];
            return;
        }
        if ((!self.voiceReady && NSProcessInfo.processInfo.systemUptime > self.voiceReadyDeadline) ||
            NSProcessInfo.processInfo.systemUptime > self.voiceDeadline) {
            BBVoiceWrite(@"cancel", @{@"session": self.voiceSession});
            [self restorePreviousApp];
            self.message.text = @"Voice input timed out. You can type your request.";
            self.voiceSession = nil;
            self.returnBundle = nil;
            [self.runButton setTitle:@"Run" forState:UIControlStateNormal];
            self.runButton.enabled = YES;
            [self.field becomeFirstResponder];
            return;
        }
        [self pollVoiceSession:generation];
    });
}

- (void)hide {
    if (!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self hide]; }); return; }
    if (self.voiceSession) {
        BBVoiceWrite(@"cancel", @{@"session": self.voiceSession});
        [self restorePreviousApp];
        self.voiceSession = nil;
        self.returnBundle = nil;
        self.voiceGeneration++;
    }
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
    if (self.voiceSession) {
        if (BBVoiceWrite(@"stop", @{@"session": self.voiceSession})) {
            self.message.text = @"Transcribing on device…";
            self.runButton.enabled = NO;
        } else self.message.text = @"Could not stop recording. Tap Close to cancel.";
        return;
    }
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
