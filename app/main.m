#import <UIKit/UIKit.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>
#import "AgentClient.h"
#import "ModelConfig.h"
#import "ModelSettingsViewController.h"
#import "ActivityStore.h"
#import "ActivityViewController.h"
#import "VoiceIPC.h"

@interface BBLocalDictation : NSObject
+ (void)transcribeFile:(NSString *)path completion:(void (^)(NSString *text, NSString *error))completion;
@end

static const char *BBHotkeyFile = "/var/mobile/Library/Caches/BeanBao/hotkey.enabled";
static const char *BBHotkeyVoiceFile = "/var/mobile/Library/Caches/BeanBao/hotkey.voice";
@interface BBRootViewController : UIViewController <UITextFieldDelegate>
@property(nonatomic, strong) UITextField *taskField;
@property(nonatomic, strong) UILabel *stateLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *feedbackLabel;
@property(nonatomic, strong) UILabel *modelLabel;
@property(nonatomic, strong) UILabel *activityLabel;
@property(nonatomic, strong) UILabel *activityTimeLabel;
@property(nonatomic, copy) NSString *previewTaskID;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) UIBarButtonItem *keyboardStartItem;
@property(nonatomic, strong) UIButton *stopButton;
@property(nonatomic, strong) UIButton *voiceButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UISwitch *hotkeySwitch;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSTimer *voiceSignalTimer;
@property(nonatomic) BOOL polling;
@property(nonatomic) BOOL recording;
@property(nonatomic) BOOL startRequestPending;
@property(nonatomic, copy) NSString *startRejection;
@property(nonatomic, copy) NSString *activeTaskID;
@property(nonatomic, copy) NSString *activeServiceID;
@property(nonatomic) NSUInteger statusEpoch;
@property(nonatomic) NSUInteger speechGeneration;
@property(nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property(nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property(nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@property(nonatomic, strong) AVAudioEngine *audioEngine;
@property(nonatomic, strong) AVAudioRecorder *localRecorder;
@property(nonatomic, strong) NSURL *localRecordingURL;
@property(nonatomic, copy) NSString *overlaySessionID;
@property(nonatomic) UIBackgroundTaskIdentifier overlayBackgroundTask;
@end

@implementation BBRootViewController

- (UILabel *)label:(NSString *)text size:(CGFloat)size {
    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:size];
    label.numberOfLines = 0;
    return label;
}

- (UIButton *)button:(NSString *)title color:(UIColor *)color action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    button.backgroundColor = color;
    button.layer.cornerRadius = 12;
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIView *)card:(NSArray<UIView *> *)items spacing:(CGFloat)spacing {
    UIView *card = [UIView new];
    card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    card.layer.cornerRadius = 18;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:items];
    content.axis = UILayoutConstraintAxisVertical;
    content.spacing = spacing;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [content.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [content.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [content.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18]
    ]];
    return card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overlayBackgroundTask = UIBackgroundTaskInvalid;
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"BeanBao";
    UIBarButtonItem *activityItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Activity"
        style:UIBarButtonItemStylePlain target:self action:@selector(activityTapped)];
    activityItem.accessibilityLabel = @"Activity";
    self.navigationItem.rightBarButtonItem = activityItem;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"BeanBaoIcon60"]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.cornerRadius = 16;
    icon.clipsToBounds = YES;
    [icon.widthAnchor constraintEqualToConstant:52].active = YES;
    [icon.heightAnchor constraintEqualToConstant:52].active = YES;
    UILabel *heading = [self label:@"Ask BeanBao" size:25];
    heading.font = [UIFont boldSystemFontOfSize:25];
    UILabel *subtitle = [self label:@"What would you like to do?" size:15];
    subtitle.textColor = UIColor.secondaryLabelColor;
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[heading, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 5;
    UIStackView *hero = [[UIStackView alloc] initWithArrangedSubviews:@[icon, titles]];
    hero.axis = UILayoutConstraintAxisHorizontal;
    hero.alignment = UIStackViewAlignmentCenter;
    hero.spacing = 12;

    UILabel *modelTitle = [self label:@"MODEL SERVICE" size:11];
    modelTitle.textColor = UIColor.secondaryLabelColor;
    self.modelLabel = [self label:@"" size:14];
    self.modelLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    UIStackView *modelInfo = [[UIStackView alloc] initWithArrangedSubviews:@[modelTitle, self.modelLabel]];
    modelInfo.axis = UILayoutConstraintAxisVertical;
    modelInfo.spacing = 5;
    UIButton *modelEdit = [UIButton buttonWithType:UIButtonTypeSystem];
    [modelEdit setTitle:@"Change  ›" forState:UIControlStateNormal];
    [modelEdit addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *modelRow = [[UIStackView alloc] initWithArrangedSubviews:@[modelInfo, modelEdit]];
    modelRow.axis = UILayoutConstraintAxisHorizontal;
    modelRow.alignment = UIStackViewAlignmentCenter;
    [modelInfo setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.taskField = [UITextField new];
    self.taskField.borderStyle = UITextBorderStyleRoundedRect;
    self.taskField.placeholder = @"e.g. Open Maps";
    self.taskField.text = @"";
    self.taskField.font = [UIFont systemFontOfSize:18];
    self.taskField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.taskField.returnKeyType = UIReturnKeyDone;
    self.taskField.delegate = self;
    UIToolbar *inputBar = [UIToolbar new];
    [inputBar sizeToFit];
    UIBarButtonItem *dismissItem = [[UIBarButtonItem alloc] initWithTitle:@"Done"
        style:UIBarButtonItemStylePlain target:self action:@selector(dismissKeyboardTapped)];
    self.keyboardStartItem = [[UIBarButtonItem alloc] initWithTitle:@"Start"
        style:UIBarButtonItemStyleDone target:self action:@selector(startTapped)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    inputBar.items = @[dismissItem, space, self.keyboardStartItem];
    self.taskField.inputAccessoryView = inputBar;
    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearButton setTitle:@"Clear" forState:UIControlStateNormal];
    [self.clearButton addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    self.voiceButton = [self button:@"🎙️ Voice input" color:UIColor.systemTealColor action:@selector(voiceTapped)];
    self.startButton = [self button:@"Start" color:UIColor.systemIndigoColor action:@selector(startTapped)];
    UILabel *composerTitle = [self label:@"New task" size:19];
    composerTitle.font = [UIFont boldSystemFontOfSize:19];
    NSArray *quickNames = @[@"Settings", @"Maps", @"Contacts", @"Notes"];
    NSMutableArray<UIView *> *quickButtons = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)quickNames.count; i++) {
        UIButton *quick = [UIButton buttonWithType:UIButtonTypeSystem];
        [quick setTitle:quickNames[i] forState:UIControlStateNormal];
        quick.tag = i;
        quick.backgroundColor = UIColor.tertiarySystemFillColor;
        quick.layer.cornerRadius = 11;
        [quick.heightAnchor constraintEqualToConstant:36].active = YES;
        [quick addTarget:self action:@selector(quickTaskTapped:) forControlEvents:UIControlEventTouchUpInside];
        [quickButtons addObject:quick];
    }
    UIStackView *quickRow = [[UIStackView alloc] initWithArrangedSubviews:quickButtons];
    quickRow.axis = UILayoutConstraintAxisHorizontal;
    quickRow.distribution = UIStackViewDistributionFillEqually;
    quickRow.spacing = 8;
    UIStackView *composerActions = [[UIStackView alloc] initWithArrangedSubviews:@[self.voiceButton, self.startButton]];
    composerActions.axis = UILayoutConstraintAxisHorizontal;
    composerActions.distribution = UIStackViewDistributionFillEqually;
    composerActions.spacing = 10;
    UIStackView *inputRow = [[UIStackView alloc] initWithArrangedSubviews:@[self.taskField, self.clearButton]];
    inputRow.axis = UILayoutConstraintAxisHorizontal;
    inputRow.alignment = UIStackViewAlignmentCenter;
    inputRow.spacing = 10;
    [self.clearButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    UILabel *hotkeyHint = [self label:@"Triple press Volume Down in another app to open BeanBao and record. Volume still changes normally." size:14];
    hotkeyHint.textColor = UIColor.secondaryLabelColor;
    self.hotkeySwitch = [UISwitch new];
    int hotkeyFD = open(BBHotkeyFile, O_RDONLY | O_NOFOLLOW);
    if (hotkeyFD >= 0) {
        char value = 0;
        self.hotkeySwitch.on = read(hotkeyFD, &value, 1) == 1 && value == '1';
        close(hotkeyFD);
    }
    [self.hotkeySwitch addTarget:self action:@selector(hotkeyChanged) forControlEvents:UIControlEventValueChanged];
    UIStackView *hotkeyRow = [[UIStackView alloc] initWithArrangedSubviews:@[hotkeyHint, self.hotkeySwitch]];
    hotkeyRow.axis = UILayoutConstraintAxisHorizontal;
    hotkeyRow.spacing = 12;
    [hotkeyHint setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];
    self.stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.stopButton setTitle:@"Stop task" forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    self.stopButton.enabled = NO;
    self.stopButton.alpha = 0.5;
    self.stopButton.hidden = YES;
    self.stateLabel = [self label:@"Connecting…" size:19];
    self.stateLabel.font = [UIFont boldSystemFontOfSize:19];
    self.detailLabel = [self label:@"" size:15];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.feedbackLabel = [self label:@"" size:15];
    self.feedbackLabel.textColor = UIColor.systemTealColor;
    UILabel *statusTitle = [self label:@"CURRENT TASK" size:11];
    statusTitle.textColor = UIColor.secondaryLabelColor;
    UILabel *hotkeyTitle = [self label:@"Volume Down shortcut" size:15];
    hotkeyTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UILabel *activityTitle = [self label:@"Recent activity" size:17];
    activityTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UIButton *activityMore = [UIButton buttonWithType:UIButtonTypeSystem];
    [activityMore setTitle:@"See all  ›" forState:UIControlStateNormal];
    [activityMore addTarget:self action:@selector(activityTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *activityHeader = [[UIStackView alloc] initWithArrangedSubviews:@[activityTitle, activityMore]];
    activityHeader.axis = UILayoutConstraintAxisHorizontal;
    activityHeader.alignment = UIStackViewAlignmentCenter;
    self.activityLabel = [self label:@"No tasks yet" size:15];
    self.activityTimeLabel = [self label:@"Completed tasks will appear here." size:13];
    self.activityTimeLabel.textColor = UIColor.secondaryLabelColor;
    UILabel *footer = [self label:@"Requests and screenshots are not stored in Activity." size:12];
    footer.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        hero, [self card:@[composerTitle, inputRow, quickRow, composerActions] spacing:14],
        self.feedbackLabel, [self card:@[statusTitle, self.stateLabel, self.detailLabel, self.stopButton] spacing:7],
        [self card:@[activityHeader, self.activityLabel, self.activityTimeLabel] spacing:7],
        [self card:@[modelRow] spacing:0], [self card:@[hotkeyTitle, hotkeyRow] spacing:10], footer]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 13;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
        [self.taskField.heightAnchor constraintEqualToConstant:52],
        [self.voiceButton.heightAnchor constraintEqualToConstant:52],
        [self.startButton.heightAnchor constraintEqualToConstant:52]
    ]];
    [self refreshModelLabel];
    [self refreshActivityPreview];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus)
                                               userInfo:nil repeats:YES];
    self.voiceSignalTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
            selector:@selector(checkHotkeyVoice) userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshModelLabel];
    [self refreshStatus];
    [self refreshActivityPreview];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self checkHotkeyVoice];
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    [self checkHotkeyVoice];
    [self refreshActivityPreview];
}

- (void)checkHotkeyVoice {
    NSDictionary *overlayStart = BBVoiceRead(@"start");
    NSTimeInterval created = [overlayStart[@"created"] doubleValue];
    BOOL overlayPending = BBVoiceValidSession(overlayStart[@"session"]) &&
        ![BBVoiceRead(@"cancel")[@"session"] isEqualToString:overlayStart[@"session"]] &&
        created > 0 && NSDate.date.timeIntervalSince1970 >= created &&
        NSDate.date.timeIntervalSince1970 - created <= 25;
    int fd = open(BBHotkeyVoiceFile, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 && !overlayPending) return;
    struct stat info = {0};
    char value = 0;
    BOOL pending = fd >= 0 && !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
        !(info.st_mode & 077) && info.st_size == 1 &&
        time(NULL) >= info.st_mtime && time(NULL) - info.st_mtime <= 10 &&
        read(fd, &value, 1) == 1 && value == '1';
    if (fd >= 0) close(fd);
    if ((!pending && !overlayPending) || self.recording) {
        if (overlayPending && self.recording) {
            BBVoiceWrite(@"result", @{@"session": overlayStart[@"session"],
                                       @"error": @"A recording is already in progress"});
            BBVoiceRemove(@"start");
        }
        unlink(BBHotkeyVoiceFile);
        return;
    }
    // viewDidAppear can precede applicationDidBecomeActive. Keep the signal
    // until UIKit reports an active, visible window, then request microphone
    // access from that foreground state.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive || !self.view.window) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ [self checkHotkeyVoice]; });
        return;
    }
    self.feedbackLabel.text = @"Shortcut received. Preparing to record…";
    unlink(BBHotkeyVoiceFile);
    if (overlayPending) {
        self.overlaySessionID = overlayStart[@"session"];
        BBVoiceRemove(@"start");
    }
    [self voiceTapped];
}

- (void)overlayVoiceFailed:(NSString *)message {
    if (!self.overlaySessionID) return;
    BBVoiceWrite(@"result", @{@"session": self.overlaySessionID,
                               @"error": message ?: @"Voice input failed"});
    self.overlaySessionID = nil;
}

- (void)checkOverlayCancel:(NSString *)session generation:(NSUInteger)generation {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![self.overlaySessionID isEqualToString:session] ||
            self.speechGeneration != generation || !self.recording) return;
        NSDictionary *cancel = BBVoiceRead(@"cancel");
        if ([cancel[@"session"] isEqualToString:session]) {
            self.speechGeneration++;
            [self.localRecorder stop];
            self.localRecorder = nil;
            self.recording = NO;
            [self.voiceButton setTitle:@"🎙️ Voice input" forState:UIControlStateNormal];
            [[NSFileManager defaultManager] removeItemAtURL:self.localRecordingURL error:nil];
            self.localRecordingURL = nil;
            [[AVAudioSession sharedInstance] setActive:NO error:nil];
            self.overlaySessionID = nil;
            BBVoiceRemove(@"cancel");
            return;
        }
        NSDictionary *stop = BBVoiceRead(@"stop");
        if ([stop[@"session"] isEqualToString:session]) {
            BBVoiceRemove(@"stop");
            [self stopRecording];
            return;
        }
        [self checkOverlayCancel:session generation:generation];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timer invalidate];
    [self.voiceSignalTimer invalidate];
    if (self.localRecorder) {
        [self.localRecorder stop];
        [[NSFileManager defaultManager] removeItemAtURL:self.localRecordingURL error:nil];
        self.localRecorder = nil;
    }
    [self stopRecording];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)dismissKeyboardTapped {
    [self.taskField resignFirstResponder];
}

- (void)showReply:(NSDictionary *)reply {
    BOOL ok = [reply[@"ok"] boolValue];
    NSString *phase = reply[@"phase"];
    BOOL running = [reply[@"running"] boolValue];
    self.stateLabel.text = ok ? (@{@"idle": @"Ready", @"running": @"Running", @"stopping": @"Stopping",
                                   @"stopped": @"Stopped", @"done": @"Completed", @"error": @"Incomplete"}[phase] ?: @"Connecting") : @"Service unavailable";
    self.detailLabel.text = ok ? (reply[@"message"] ?: @"") : (reply[@"error"] ?: @"Could not connect to the on-device service");
    self.startButton.enabled = !running;
    self.keyboardStartItem.enabled = !running;
    self.startButton.alpha = running ? 0.5 : 1.0;
    self.stopButton.enabled = running;
    self.stopButton.alpha = running ? 1.0 : 0.5;
    self.stopButton.hidden = !running;
    NSString *taskID = reply[@"task_id"];
    if (ok && !running && [taskID isKindOfClass:NSString.class] && taskID.length &&
        ![self.previewTaskID isEqualToString:taskID]) {
        self.previewTaskID = taskID;
        [self refreshActivityPreview];
    }
}

- (void)refreshActivityPreview {
    NSDictionary *latest = BBRecentActivity(1).firstObject;
    if (!latest) {
        self.activityLabel.text = @"No tasks yet";
        self.activityTimeLabel.text = @"Completed tasks will appear here.";
        return;
    }
    NSString *state = latest[@"state"];
    NSString *outcome = [state isEqualToString:@"done"] ? @"Completed" :
        ([state isEqualToString:@"error"] ? @"Incomplete" :
         ([state isEqualToString:@"stopped"] ? @"Stopped" : @"Started"));
    self.activityLabel.text = latest[@"title"];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterShortStyle;
    self.activityTimeLabel.text = [NSString stringWithFormat:@"%@ · %@", outcome,
        [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:[latest[@"time"] doubleValue]]]];
}

- (void)activityTapped {
    [self.taskField resignFirstResponder];
    [self.navigationController pushViewController:[BBActivityViewController new] animated:YES];
}

- (void)request:(NSDictionary *)payload {
    BOOL starting = [payload[@"op"] isEqualToString:@"start"];
    NSUInteger epoch = self.statusEpoch;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(payload);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch != self.statusEpoch) return;
            if (starting) {
                self.startRequestPending = NO;
                NSString *taskID = [reply[@"task_id"] isKindOfClass:NSString.class] ? reply[@"task_id"] : nil;
                NSString *serviceID = [reply[@"service_id"] isKindOfClass:NSString.class] ? reply[@"service_id"] : nil;
                if (![reply[@"ok"] boolValue] || !taskID.length || !serviceID.length) {
                    self.startRejection = ![reply[@"ok"] boolValue] && [reply[@"error"] isKindOfClass:NSString.class] ?
                        reply[@"error"] : @"Task status protocol is incompatible. Update BeanBao Agent.";
                    self.stateLabel.text = @"Not started";
                    self.detailLabel.text = self.startRejection;
                    self.startButton.enabled = YES;
                    self.keyboardStartItem.enabled = YES;
                    self.startButton.alpha = 1.0;
                    self.stopButton.enabled = NO;
                    self.stopButton.alpha = 0.5;
                    return;
                }
                self.activeTaskID = taskID;
                self.activeServiceID = serviceID;
            } else if (![reply[@"ok"] boolValue]) {
                self.stateLabel.text = @"Not stopped";
                self.detailLabel.text = [reply[@"error"] isKindOfClass:NSString.class] ?
                    reply[@"error"] : @"Could not stop the task";
                return;
            }
            [self showReply:reply];
        });
    });
}

- (void)refreshStatus {
    if (self.polling || self.startRequestPending) return;
    self.polling = YES;
    NSUInteger epoch = self.statusEpoch;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"status"});
        dispatch_async(dispatch_get_main_queue(), ^{
            self.polling = NO;
            if (self.startRequestPending || epoch != self.statusEpoch || self.startRejection.length) return;
            if (![reply[@"ok"] boolValue] && self.activeTaskID.length) {
                self.stateLabel.text = @"Reconnecting to service";
                self.detailLabel.text = @"Task result is temporarily unavailable. It will be checked after reconnection.";
                self.startButton.enabled = NO;
                self.keyboardStartItem.enabled = NO;
                self.startButton.alpha = 0.5;
                self.stopButton.enabled = NO;
                self.stopButton.alpha = 0.5;
                return;
            }
            if (self.activeTaskID.length) {
                BOOL sameService = [reply[@"service_id"] isEqualToString:self.activeServiceID];
                BOOL sameTask = [reply[@"task_id"] isEqualToString:self.activeTaskID];
                if (!sameService || !sameTask) {
                    self.statusEpoch++;
                    self.activeTaskID = nil;
                    self.activeServiceID = nil;
                    self.startRejection = sameService ? @"The task changed. Check the target app and try again." :
                        @"The service restarted. Check the target app before retrying.";
                    self.stateLabel.text = @"Status unknown";
                    self.detailLabel.text = self.startRejection;
                    self.startButton.enabled = YES;
                    self.keyboardStartItem.enabled = YES;
                    self.startButton.alpha = 1.0;
                    self.stopButton.enabled = NO;
                    self.stopButton.alpha = 0.5;
                    return;
                }
            }
            [self showReply:reply];
        });
    });
}

- (void)startTapped {
    if (self.startRequestPending || !self.startButton.enabled) return;
    [self.taskField resignFirstResponder];
    NSString *task = [self.taskField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!task.length) { self.feedbackLabel.text = @"Enter a request"; return; }
    self.feedbackLabel.text = @"";
    self.statusEpoch++;
    self.startRejection = nil;
    self.activeTaskID = nil;
    self.activeServiceID = nil;
    self.startRequestPending = YES;
    self.stateLabel.text = @"Submitting…";
    self.detailLabel.text = @"";
    self.startButton.enabled = NO;
    self.keyboardStartItem.enabled = NO;
    [self request:@{@"op": @"start", @"task": task}];
}

- (void)stopTapped {
    NSMutableDictionary *request = [@{@"op": @"stop"} mutableCopy];
    if (self.activeTaskID.length) request[@"task_id"] = self.activeTaskID;
    if (self.activeServiceID.length) request[@"service_id"] = self.activeServiceID;
    [self request:request];
}

- (void)clearTapped { self.taskField.text = @""; [self.taskField resignFirstResponder]; }

- (void)refreshModelLabel {
    NSDictionary *config = BBModelLoad();
    NSString *provider = config[@"provider"];
    NSString *model = BBModelProfile(config, provider)[@"model"] ?: @"";
    self.modelLabel.text = [NSString stringWithFormat:@"%@ · %@%@", BBModelProviderName(provider), model,
        BBModelReadKey(provider) ? @"" : @" · API key needed"];
}

- (void)settingsTapped {
    [self.taskField resignFirstResponder];
    BBModelSettingsViewController *settings = [BBModelSettingsViewController new];
    __weak typeof(self) weakSelf = self;
    settings.onSave = ^{ [weakSelf refreshModelLabel]; };
    [self.navigationController pushViewController:settings animated:YES];
}

- (void)quickTaskTapped:(UIButton *)sender {
    NSArray *tasks = @[@"Open Settings", @"Open Maps", @"Open Contacts", @"Open Notes"];
    if (sender.tag < 0 || sender.tag >= (NSInteger)tasks.count) return;
    self.taskField.text = tasks[sender.tag];
    self.feedbackLabel.text = @"Request added. Tap Start to run it.";
}

- (void)hotkeyChanged {
    int fd = open(BBHotkeyFile, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0 || fchmod(fd, 0600) || write(fd, self.hotkeySwitch.on ? "1" : "0", 1) != 1) {
        if (fd >= 0) close(fd);
        self.hotkeySwitch.on = !self.hotkeySwitch.on;
        self.feedbackLabel.text = @"Could not save the shortcut setting";
        return;
    }
    close(fd);
    self.feedbackLabel.text = self.hotkeySwitch.on ? @"Volume Down shortcut enabled" : @"Volume Down shortcut disabled";
}

- (void)voiceTapped {
    if (self.recording) { [self stopRecording]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                self.feedbackLabel.text = @"Speech recognition is not allowed. You can still type.";
                [self overlayVoiceFailed:@"Speech recognition is not allowed"];
                return;
            }
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [self startRecording];
                    else {
                        self.feedbackLabel.text = @"Microphone access is not allowed. You can still type.";
                        [self overlayVoiceFailed:@"Microphone access is not allowed"];
                    }
                });
            }];
        });
    }];
}

- (void)startRecording {
    if (self.recording) return;
    if (@available(iOS 26.0, *)) {
        [self startLocalRecording];
        return;
    }
    [self.speechTask cancel];
    self.speechTask = nil;
    self.speechGeneration++;
    NSUInteger generation = self.speechGeneration;
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!self.speechRecognizer || !self.speechRecognizer.isAvailable) {
        self.feedbackLabel.text = @"English speech recognition is unavailable";
        return;
    }
    self.speechRequest = [SFSpeechAudioBufferRecognitionRequest new];
    self.speechRequest.shouldReportPartialResults = YES;
    BOOL onDevice = self.speechRecognizer.supportsOnDeviceRecognition;
    self.speechRequest.requiresOnDeviceRecognition = onDevice;
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:0 error:&error];
    if (!error) [session setActive:YES error:&error];
    if (error) { self.feedbackLabel.text = @"Could not start the microphone"; self.speechRequest = nil; return; }
    self.audioEngine = [AVAudioEngine new];
    AVAudioInputNode *input = self.audioEngine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    __weak typeof(self) weakSelf = self;
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        [weakSelf.speechRequest appendAudioPCMBuffer:buffer];
    }];
    [self.audioEngine prepare];
    if (![self.audioEngine startAndReturnError:&error]) {
        [input removeTapOnBus:0];
        self.audioEngine = nil;
        self.speechRequest = nil;
        self.feedbackLabel.text = @"Could not start recording";
        return;
    }
    self.recording = YES;
    [self.voiceButton setTitle:@"Stop recording" forState:UIControlStateNormal];
    self.feedbackLabel.text = onDevice ? @"Recognizing on device. You can edit the result." : @"Recognizing with Apple Speech. You can edit the result.";
    self.speechTask = [self.speechRecognizer recognitionTaskWithRequest:self.speechRequest resultHandler:^(SFSpeechRecognitionResult *result, NSError *failure) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.speechGeneration != generation) return;
            if (result.bestTranscription.formattedString.length)
                strongSelf.taskField.text = result.bestTranscription.formattedString;
            if (result.isFinal || failure) {
                [strongSelf stopRecording];
                strongSelf.speechTask = nil;
                if (failure && !result.bestTranscription.formattedString.length)
                    strongSelf.feedbackLabel.text = [NSString stringWithFormat:
                        @"Speech recognition failed (%@:%ld). Please type your request.",
                        failure.domain ?: @"unknown", (long)failure.code];
            }
        });
    }];
}

- (void)startLocalRecording {
    self.speechGeneration++;
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeDefault options:0 error:&error];
    if (!error) [session setActive:YES error:&error];
    if (error) {
        self.feedbackLabel.text = @"Could not start the microphone";
        [self overlayVoiceFailed:@"Could not start the microphone"];
        return;
    }
    self.localRecordingURL = [NSURL fileURLWithPath:
        [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"beanbao-voice-%@.caf", NSUUID.UUID.UUIDString]]];
    NSDictionary *settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @16000, AVNumberOfChannelsKey: @1,
        AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO};
    self.localRecorder = [[AVAudioRecorder alloc] initWithURL:self.localRecordingURL
                                                      settings:settings error:&error];
    if (error || ![self.localRecorder record]) {
        self.localRecorder = nil;
        [[NSFileManager defaultManager] removeItemAtURL:self.localRecordingURL error:nil];
        self.localRecordingURL = nil;
        [session setActive:NO error:nil];
        self.feedbackLabel.text = @"Could not start recording";
        [self overlayVoiceFailed:@"Could not start recording"];
        return;
    }
    self.recording = YES;
    [self.voiceButton setTitle:@"Stop recording" forState:UIControlStateNormal];
    self.feedbackLabel.text = @"Recording. Transcription starts when you stop.";
    NSUInteger generation = self.speechGeneration;
    NSString *overlaySession = self.overlaySessionID;
    if (overlaySession) {
        BBVoiceWrite(@"ready", @{@"session": overlaySession});
        [self checkOverlayCancel:overlaySession generation:generation];
    }
    NSTimeInterval duration = 30;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.recording && self.localRecorder && self.speechGeneration == generation)
            [self stopRecording];
    });
}

- (void)stopRecording {
    if (self.localRecorder) {
        NSString *overlaySession = self.overlaySessionID;
        if (overlaySession) {
            self.overlayBackgroundTask = [[UIApplication sharedApplication]
                beginBackgroundTaskWithExpirationHandler:^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (self.overlayBackgroundTask != UIBackgroundTaskInvalid) {
                            [[UIApplication sharedApplication] endBackgroundTask:self.overlayBackgroundTask];
                            self.overlayBackgroundTask = UIBackgroundTaskInvalid;
                        }
                    });
                }];
        }
        [self.localRecorder stop];
        self.localRecorder = nil;
        self.recording = NO;
        [self.voiceButton setTitle:@"🎙️ Voice input" forState:UIControlStateNormal];
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
        NSUInteger generation = self.speechGeneration;
        NSString *path = self.localRecordingURL.path;
        self.localRecordingURL = nil;
        self.feedbackLabel.text = @"Transcribing on device. English language assets may download on first use.";
        __weak typeof(self) weakSelf = self;
        [BBLocalDictation transcribeFile:path completion:^(NSString *text, NSString *failure) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (strongSelf.speechGeneration != generation) {
                if (strongSelf.overlayBackgroundTask != UIBackgroundTaskInvalid) {
                    [[UIApplication sharedApplication] endBackgroundTask:strongSelf.overlayBackgroundTask];
                    strongSelf.overlayBackgroundTask = UIBackgroundTaskInvalid;
                }
                return;
            }
            if (text.length) {
                strongSelf.taskField.text = text;
                strongSelf.feedbackLabel.text = @"Transcription ready. Edit it if needed, then tap Start.";
            } else {
                strongSelf.feedbackLabel.text = [NSString stringWithFormat:
                    @"On-device transcription failed (%@). Please type your request.", failure ?: @"unknown"];
            }
            if ([strongSelf.overlaySessionID isEqualToString:overlaySession] &&
                ![BBVoiceRead(@"cancel")[@"session"] isEqualToString:overlaySession]) {
                NSMutableDictionary *result = [@{@"session": overlaySession} mutableCopy];
                if (text.length) result[@"text"] = text;
                else result[@"error"] = failure ?: @"No speech recognized";
                BBVoiceWrite(@"result", result);
                strongSelf.overlaySessionID = nil;
            }
            if (strongSelf.overlayBackgroundTask != UIBackgroundTaskInvalid) {
                [[UIApplication sharedApplication] endBackgroundTask:strongSelf.overlayBackgroundTask];
                strongSelf.overlayBackgroundTask = UIBackgroundTaskInvalid;
            }
        }];
        return;
    }
    if (!self.recording && !self.audioEngine) return;
    self.recording = NO;
    [self.audioEngine stop];
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.speechRequest endAudio];
    self.audioEngine = nil;
    self.speechRequest = nil;
    [self.voiceButton setTitle:@"🎙️ Voice input" forState:UIControlStateNormal];
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    self.feedbackLabel.text = @"Check or edit the transcript, then tap Start.";
}

@end

@interface BBAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation BBAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[BBRootViewController new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(BBAppDelegate.class)); }
}
