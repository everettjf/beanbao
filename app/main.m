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
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) UIBarButtonItem *keyboardStartItem;
@property(nonatomic, strong) UIButton *stopButton;
@property(nonatomic, strong) UIButton *voiceButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UISwitch *hotkeySwitch;
@property(nonatomic, strong) NSTimer *timer;
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
    card.layer.cornerRadius = 20;
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
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"BeanBao";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"slider.horizontal.3"]
        style:UIBarButtonItemStylePlain target:self action:@selector(settingsTapped)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel = @"模型设置";
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"BeanBaoIcon60"]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.layer.cornerRadius = 16;
    icon.clipsToBounds = YES;
    [icon.widthAnchor constraintEqualToConstant:64].active = YES;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;
    UILabel *heading = [self label:@"嗨，我是豆包" size:28];
    heading.font = [UIFont boldSystemFontOfSize:28];
    UILabel *subtitle = [self label:@"一句话，帮你把手机上的小事做好。" size:15];
    subtitle.textColor = UIColor.secondaryLabelColor;
    UIStackView *titles = [[UIStackView alloc] initWithArrangedSubviews:@[heading, subtitle]];
    titles.axis = UILayoutConstraintAxisVertical;
    titles.spacing = 5;
    UIStackView *hero = [[UIStackView alloc] initWithArrangedSubviews:@[icon, titles]];
    hero.axis = UILayoutConstraintAxisHorizontal;
    hero.alignment = UIStackViewAlignmentCenter;
    hero.spacing = 14;

    UILabel *modelTitle = [self label:@"当前模型服务" size:13];
    modelTitle.textColor = UIColor.secondaryLabelColor;
    self.modelLabel = [self label:@"" size:16];
    self.modelLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    UIStackView *modelInfo = [[UIStackView alloc] initWithArrangedSubviews:@[modelTitle, self.modelLabel]];
    modelInfo.axis = UILayoutConstraintAxisVertical;
    modelInfo.spacing = 5;
    UIButton *modelEdit = [UIButton buttonWithType:UIButtonTypeSystem];
    [modelEdit setTitle:@"管理  ›" forState:UIControlStateNormal];
    [modelEdit addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *modelRow = [[UIStackView alloc] initWithArrangedSubviews:@[modelInfo, modelEdit]];
    modelRow.axis = UILayoutConstraintAxisHorizontal;
    modelRow.alignment = UIStackViewAlignmentCenter;
    [modelInfo setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    self.taskField = [UITextField new];
    self.taskField.borderStyle = UITextBorderStyleRoundedRect;
    self.taskField.placeholder = @"例如：打开地图";
    self.taskField.text = @"打开地图";
    self.taskField.font = [UIFont systemFontOfSize:18];
    self.taskField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.taskField.returnKeyType = UIReturnKeyDone;
    self.taskField.delegate = self;
    UIToolbar *inputBar = [UIToolbar new];
    [inputBar sizeToFit];
    UIBarButtonItem *dismissItem = [[UIBarButtonItem alloc] initWithTitle:@"完成"
        style:UIBarButtonItemStylePlain target:self action:@selector(dismissKeyboardTapped)];
    self.keyboardStartItem = [[UIBarButtonItem alloc] initWithTitle:@"开始"
        style:UIBarButtonItemStyleDone target:self action:@selector(startTapped)];
    UIBarButtonItem *space = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
    inputBar.items = @[dismissItem, space, self.keyboardStartItem];
    self.taskField.inputAccessoryView = inputBar;
    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearButton setTitle:@"清空输入" forState:UIControlStateNormal];
    [self.clearButton addTarget:self action:@selector(clearTapped) forControlEvents:UIControlEventTouchUpInside];
    self.voiceButton = [self button:@"🎙️ 语音输入" color:UIColor.systemTealColor action:@selector(voiceTapped)];
    self.startButton = [self button:@"开始" color:UIColor.systemIndigoColor action:@selector(startTapped)];
    UILabel *composerTitle = [self label:@"想让我做什么？" size:20];
    composerTitle.font = [UIFont boldSystemFontOfSize:20];
    NSArray *quickNames = @[@"设置", @"地图", @"通讯录", @"备忘录"];
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

    UILabel *hotkeyHint = [self label:@"在其他 App 三连按音量下键打开 BeanBao 并录音（音量仍照常变化）" size:14];
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
    [self.stopButton setTitle:@"停止任务" forState:UIControlStateNormal];
    [self.stopButton addTarget:self action:@selector(stopTapped) forControlEvents:UIControlEventTouchUpInside];
    self.stopButton.enabled = NO;
    self.stopButton.alpha = 0.5;
    self.stateLabel = [self label:@"连接中…" size:19];
    self.stateLabel.font = [UIFont boldSystemFontOfSize:19];
    self.detailLabel = [self label:@"" size:15];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    self.feedbackLabel = [self label:@"" size:15];
    self.feedbackLabel.textColor = UIColor.systemTealColor;
    UILabel *statusTitle = [self label:@"任务状态" size:13];
    statusTitle.textColor = UIColor.secondaryLabelColor;
    UILabel *hotkeyTitle = [self label:@"快捷唤醒" size:17];
    hotkeyTitle.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UILabel *footer = [self label:@"只执行可核对的任务；遇锁屏或界面变化会停下。" size:13];
    footer.textColor = UIColor.tertiaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        hero, [self card:@[modelRow] spacing:0],
        [self card:@[composerTitle, self.taskField, quickRow, composerActions, self.clearButton] spacing:15],
        [self card:@[statusTitle, self.stateLabel, self.detailLabel, self.stopButton] spacing:9],
        [self card:@[hotkeyTitle, hotkeyRow] spacing:12], self.feedbackLabel, footer]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
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
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
        [self.taskField.heightAnchor constraintEqualToConstant:52],
        [self.voiceButton.heightAnchor constraintEqualToConstant:52],
        [self.startButton.heightAnchor constraintEqualToConstant:52]
    ]];
    [self refreshModelLabel];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus)
                                               userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshModelLabel];
    [self refreshStatus];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self checkHotkeyVoice];
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    [self checkHotkeyVoice];
}

- (void)checkHotkeyVoice {
    int fd = open(BBHotkeyVoiceFile, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return;
    struct stat info = {0};
    char value = 0;
    BOOL pending = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
        !(info.st_mode & 077) && info.st_size == 1 &&
        time(NULL) >= info.st_mtime && time(NULL) - info.st_mtime <= 10 &&
        read(fd, &value, 1) == 1 && value == '1';
    close(fd);
    if (!pending || self.recording) {
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
    self.feedbackLabel.text = @"已收到按键唤醒，正在准备录音";
    unlink(BBHotkeyVoiceFile);
    [self voiceTapped];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.timer invalidate];
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
    self.stateLabel.text = ok ? (@{@"idle": @"待命", @"running": @"执行中", @"stopping": @"正在停止",
                                   @"stopped": @"已停止", @"done": @"已完成", @"error": @"未完成"}[phase] ?: @"连接中") : @"服务不可用";
    self.detailLabel.text = ok ? (reply[@"message"] ?: @"") : (reply[@"error"] ?: @"无法连接本机服务");
    self.startButton.enabled = !running;
    self.keyboardStartItem.enabled = !running;
    self.startButton.alpha = running ? 0.5 : 1.0;
    self.stopButton.enabled = running;
    self.stopButton.alpha = running ? 1.0 : 0.5;
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
                        reply[@"error"] : @"任务状态协议不兼容，请更新 BeanBao Agent";
                    self.stateLabel.text = @"未开始";
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
                self.stateLabel.text = @"未停止";
                self.detailLabel.text = [reply[@"error"] isKindOfClass:NSString.class] ?
                    reply[@"error"] : @"停止请求未成功";
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
                self.stateLabel.text = @"服务连接中";
                self.detailLabel.text = @"暂时无法确认任务结果，连接恢复后会重新核对";
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
                    self.startRejection = sameService ? @"任务已变化，请核对目标 App 后重试" :
                        @"服务已重启，上一任务结果未知；请核对目标 App";
                    self.stateLabel.text = @"状态未知";
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
    if (!task.length) { self.feedbackLabel.text = @"请输入文字指令"; return; }
    self.feedbackLabel.text = @"";
    self.statusEpoch++;
    self.startRejection = nil;
    self.activeTaskID = nil;
    self.activeServiceID = nil;
    self.startRequestPending = YES;
    self.stateLabel.text = @"提交中";
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
        BBModelReadKey(provider) ? @"" : @" · 待配置 Key"];
}

- (void)settingsTapped {
    [self.taskField resignFirstResponder];
    BBModelSettingsViewController *settings = [BBModelSettingsViewController new];
    __weak typeof(self) weakSelf = self;
    settings.onSave = ^{ [weakSelf refreshModelLabel]; };
    [self.navigationController pushViewController:settings animated:YES];
}

- (void)quickTaskTapped:(UIButton *)sender {
    NSArray *tasks = @[@"打开设置", @"打开地图", @"打开通讯录", @"打开备忘录"];
    if (sender.tag < 0 || sender.tag >= (NSInteger)tasks.count) return;
    self.taskField.text = tasks[sender.tag];
    self.feedbackLabel.text = @"已填入指令，点开始后执行";
}

- (void)hotkeyChanged {
    int fd = open(BBHotkeyFile, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0 || fchmod(fd, 0600) || write(fd, self.hotkeySwitch.on ? "1" : "0", 1) != 1) {
        if (fd >= 0) close(fd);
        self.hotkeySwitch.on = !self.hotkeySwitch.on;
        self.feedbackLabel.text = @"按键设置保存失败";
        return;
    }
    close(fd);
    self.feedbackLabel.text = self.hotkeySwitch.on ? @"音量下键三连按已启用" : @"按键唤醒已关闭";
}

- (void)voiceTapped {
    if (self.recording) { [self stopRecording]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                self.feedbackLabel.text = @"语音识别未获授权，仍可输入文字";
                return;
            }
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [self startRecording];
                    else self.feedbackLabel.text = @"麦克风未获授权，仍可输入文字";
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
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    if (!self.speechRecognizer || !self.speechRecognizer.isAvailable) {
        self.feedbackLabel.text = @"当前中文语音识别不可用";
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
    if (error) { self.feedbackLabel.text = @"无法启动麦克风"; self.speechRequest = nil; return; }
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
        self.feedbackLabel.text = @"录音启动失败";
        return;
    }
    self.recording = YES;
    [self.voiceButton setTitle:@"结束录音" forState:UIControlStateNormal];
    self.feedbackLabel.text = onDevice ? @"正在本机识别，结束后可修改文字" : @"正在通过 Apple 语音服务识别，结束后可修改文字";
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
                        @"语音识别未完成（%@:%ld），请改用文字输入",
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
    if (error) { self.feedbackLabel.text = @"无法启动麦克风"; return; }
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
        self.feedbackLabel.text = @"录音启动失败";
        return;
    }
    self.recording = YES;
    [self.voiceButton setTitle:@"结束录音" forState:UIControlStateNormal];
    self.feedbackLabel.text = @"正在录音，结束后在本机转写";
    NSUInteger generation = self.speechGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.recording && self.localRecorder && self.speechGeneration == generation)
            [self stopRecording];
    });
}

- (void)stopRecording {
    if (self.localRecorder) {
        [self.localRecorder stop];
        self.localRecorder = nil;
        self.recording = NO;
        [self.voiceButton setTitle:@"🎙️ 语音输入" forState:UIControlStateNormal];
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
        NSUInteger generation = self.speechGeneration;
        NSString *path = self.localRecordingURL.path;
        self.localRecordingURL = nil;
        self.feedbackLabel.text = @"正在本机转写；首次使用可能下载中文资源";
        __weak typeof(self) weakSelf = self;
        [BBLocalDictation transcribeFile:path completion:^(NSString *text, NSString *failure) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.speechGeneration != generation) return;
            if (text.length) {
                strongSelf.taskField.text = text;
                strongSelf.feedbackLabel.text = @"转写完成；可修改文字后点开始";
            } else {
                strongSelf.feedbackLabel.text = [NSString stringWithFormat:
                    @"本机转写未完成（%@），请改用文字输入", failure ?: @"unknown"];
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
    [self.voiceButton setTitle:@"🎙️ 语音输入" forState:UIControlStateNormal];
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
    self.feedbackLabel.text = @"转写文字可修改，确认后点开始";
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
