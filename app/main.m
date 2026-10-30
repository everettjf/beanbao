#import <UIKit/UIKit.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <unistd.h>
#import "AgentClient.h"

static const char *BBHotkeyFile = "/var/mobile/Library/Caches/BeanBao/hotkey.enabled";

@interface BBRootViewController : UIViewController <UITextFieldDelegate>
@property(nonatomic, strong) UITextField *taskField;
@property(nonatomic, strong) UISegmentedControl *modelControl;
@property(nonatomic, strong) UILabel *stateLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UIButton *startButton;
@property(nonatomic, strong) UIButton *stopButton;
@property(nonatomic, strong) UIButton *voiceButton;
@property(nonatomic, strong) UIButton *clearButton;
@property(nonatomic, strong) UISwitch *hotkeySwitch;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic) BOOL polling;
@property(nonatomic) BOOL recording;
@property(nonatomic) NSUInteger speechGeneration;
@property(nonatomic, strong) SFSpeechRecognizer *speechRecognizer;
@property(nonatomic, strong) SFSpeechAudioBufferRecognitionRequest *speechRequest;
@property(nonatomic, strong) SFSpeechRecognitionTask *speechTask;
@property(nonatomic, strong) AVAudioEngine *audioEngine;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"BeanBao";
    UILabel *heading = [self label:@"手机端文字指令" size:28];
    heading.font = [UIFont boldSystemFontOfSize:28];
    UILabel *hint = [self label:@"可用：打开设置、备忘录或地图；Claude 模式还可输入“在地图搜索金门大桥”。操作前请解锁手机。" size:15];
    hint.textColor = UIColor.secondaryLabelColor;
    self.taskField = [UITextField new];
    self.taskField.borderStyle = UITextBorderStyleRoundedRect;
    self.taskField.placeholder = @"例如：打开地图";
    self.taskField.text = @"打开地图";
    self.taskField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.taskField.returnKeyType = UIReturnKeyDone;
    self.taskField.delegate = self;
    self.clearButton = [self button:@"清空输入" color:UIColor.systemGrayColor action:@selector(clearTapped)];
    self.modelControl = [[UISegmentedControl alloc] initWithItems:@[@"模拟模型", @"Claude"]];
    self.modelControl.selectedSegmentIndex = 0;
    self.voiceButton = [self button:@"🎙️ 语音输入" color:UIColor.systemTealColor action:@selector(voiceTapped)];
    UILabel *hotkeyHint = [self label:@"三连按音量下键打开 BeanBao（音量仍照常变化）" size:14];
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
    self.startButton = [self button:@"开始" color:UIColor.systemBlueColor action:@selector(startTapped)];
    self.stopButton = [self button:@"停止任务" color:UIColor.systemRedColor action:@selector(stopTapped)];
    self.stopButton.enabled = NO;
    self.stopButton.alpha = 0.5;
    self.stateLabel = [self label:@"连接中…" size:18];
    self.stateLabel.font = [UIFont boldSystemFontOfSize:18];
    self.detailLabel = [self label:@"" size:15];
    self.detailLabel.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        heading, hint, self.taskField, self.clearButton, self.voiceButton, self.modelControl, self.startButton,
        self.stopButton, hotkeyRow, self.stateLabel, self.detailLabel]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:32],
        [self.taskField.heightAnchor constraintEqualToConstant:48],
        [self.clearButton.heightAnchor constraintEqualToConstant:42],
        [self.voiceButton.heightAnchor constraintEqualToConstant:48],
        [self.startButton.heightAnchor constraintEqualToConstant:48],
        [self.stopButton.heightAnchor constraintEqualToConstant:48],
    ]];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus)
                                               userInfo:nil repeats:YES];
    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

- (void)dealloc { [self.timer invalidate]; [self stopRecording]; }

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)showReply:(NSDictionary *)reply {
    BOOL ok = [reply[@"ok"] boolValue];
    NSString *phase = reply[@"phase"];
    BOOL running = [reply[@"running"] boolValue];
    self.stateLabel.text = ok ? (@{@"idle": @"待命", @"running": @"执行中", @"stopping": @"正在停止",
                                   @"stopped": @"已停止", @"done": @"已完成", @"error": @"未完成"}[phase] ?: @"连接中") : @"服务不可用";
    self.detailLabel.text = ok ? (reply[@"message"] ?: @"") : (reply[@"error"] ?: @"无法连接本机服务");
    self.startButton.enabled = !running;
    self.startButton.alpha = running ? 0.5 : 1.0;
    self.stopButton.enabled = running;
    self.stopButton.alpha = running ? 1.0 : 0.5;
}

- (void)request:(NSDictionary *)payload {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(payload);
        dispatch_async(dispatch_get_main_queue(), ^{ [self showReply:reply]; });
    });
}

- (void)refreshStatus {
    if (self.polling) return;
    self.polling = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"status"});
        dispatch_async(dispatch_get_main_queue(), ^{
            self.polling = NO;
            [self showReply:reply];
        });
    });
}

- (void)startTapped {
    [self.taskField resignFirstResponder];
    NSString *task = [self.taskField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!task.length) { self.detailLabel.text = @"请输入文字指令"; return; }
    self.startButton.enabled = NO;
    [self request:@{@"op": @"start", @"task": task,
                    @"model": self.modelControl.selectedSegmentIndex == 1 ? @"claude" : @"mock"}];
}

- (void)stopTapped { [self request:@{@"op": @"stop"}]; }

- (void)clearTapped { self.taskField.text = @""; [self.taskField resignFirstResponder]; }

- (void)hotkeyChanged {
    int fd = open(BBHotkeyFile, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0 || fchmod(fd, 0600) || write(fd, self.hotkeySwitch.on ? "1" : "0", 1) != 1) {
        if (fd >= 0) close(fd);
        self.hotkeySwitch.on = !self.hotkeySwitch.on;
        self.detailLabel.text = @"按键设置保存失败";
        return;
    }
    close(fd);
    self.detailLabel.text = self.hotkeySwitch.on ? @"音量下键三连按已启用" : @"按键唤醒已关闭";
}

- (void)voiceTapped {
    if (self.recording) { [self stopRecording]; return; }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                self.detailLabel.text = @"语音识别未获授权，仍可输入文字";
                return;
            }
            [[AVAudioSession sharedInstance] requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) [self startRecording];
                    else self.detailLabel.text = @"麦克风未获授权，仍可输入文字";
                });
            }];
        });
    }];
}

- (void)startRecording {
    if (self.recording) return;
    [self.speechTask cancel];
    self.speechTask = nil;
    self.speechGeneration++;
    NSUInteger generation = self.speechGeneration;
    self.speechRecognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"zh-CN"]];
    if (!self.speechRecognizer || !self.speechRecognizer.isAvailable) {
        self.detailLabel.text = @"当前中文语音识别不可用";
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
    if (error) { self.detailLabel.text = @"无法启动麦克风"; self.speechRequest = nil; return; }
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
        self.detailLabel.text = @"录音启动失败";
        return;
    }
    self.recording = YES;
    [self.voiceButton setTitle:@"结束录音" forState:UIControlStateNormal];
    self.detailLabel.text = onDevice ? @"正在本机识别，结束后可修改文字" : @"正在通过 Apple 语音服务识别，结束后可修改文字";
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
                    strongSelf.detailLabel.text = @"语音识别未完成，请改用文字输入";
            }
        });
    }];
}

- (void)stopRecording {
    if (!self.recording && !self.audioEngine) return;
    self.recording = NO;
    [self.audioEngine stop];
    [self.audioEngine.inputNode removeTapOnBus:0];
    [self.speechRequest endAudio];
    self.audioEngine = nil;
    self.speechRequest = nil;
    [self.voiceButton setTitle:@"🎙️ 语音输入" forState:UIControlStateNormal];
    self.detailLabel.text = @"转写文字可修改，确认后点开始";
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
