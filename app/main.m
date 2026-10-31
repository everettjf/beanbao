#import <UIKit/UIKit.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <time.h>
#import <unistd.h>
#import "AgentClient.h"

@interface BBLocalDictation : NSObject
+ (void)transcribeFile:(NSString *)path completion:(void (^)(NSString *text, NSString *error))completion;
@end

static const char *BBHotkeyFile = "/var/mobile/Library/Caches/BeanBao/hotkey.enabled";
static const char *BBHotkeyVoiceFile = "/var/mobile/Library/Caches/BeanBao/hotkey.voice";
static const char *BBKeyFile = "/var/mobile/Library/Application Support/BeanBao/claude.key";

static BOOL BBSaveClaudeKey(NSString *key) {
    if (![key hasPrefix:@"sk-ant-"] || key.length < 24 || key.length > 4000 ||
        [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) return NO;
    NSString *directory = @"/var/mobile/Library/Application Support/BeanBao";
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0700} error:nil]) return NO;
    struct stat directoryInfo = {0};
    if (lstat(directory.fileSystemRepresentation, &directoryInfo) || !S_ISDIR(directoryInfo.st_mode) ||
        directoryInfo.st_uid != getuid() || chmod(directory.fileSystemRepresentation, 0700)) return NO;
    NSData *bytes = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > 4096) return NO;
    NSString *temporary = [NSString stringWithFormat:@"%s.tmp.%@", BBKeyFile, NSUUID.UUID.UUIDString];
    int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) return NO;
    const uint8_t *cursor = bytes.bytes;
    NSUInteger remaining = bytes.length;
    while (remaining) {
        ssize_t written = write(fd, cursor, remaining);
        if (written <= 0) { close(fd); unlink(temporary.fileSystemRepresentation); return NO; }
        cursor += written; remaining -= (NSUInteger)written;
    }
    BOOL saved = !fchmod(fd, 0600) && !fsync(fd);
    close(fd);
    if (!saved || rename(temporary.fileSystemRepresentation, BBKeyFile)) {
        unlink(temporary.fileSystemRepresentation); return NO;
    }
    return YES;
}

@interface BBRootViewController : UIViewController <UITextFieldDelegate>
@property(nonatomic, strong) UITextField *taskField;
@property(nonatomic, strong) UISegmentedControl *modelControl;
@property(nonatomic, strong) UILabel *stateLabel;
@property(nonatomic, strong) UILabel *detailLabel;
@property(nonatomic, strong) UILabel *feedbackLabel;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"BeanBao";
    UILabel *heading = [self label:@"手机端文字指令" size:28];
    heading.font = [UIFont boldSystemFontOfSize:28];
    UILabel *hint = [self label:@"可用：打开设置、备忘录或地图，以及“新建备忘录：测试内容”；Claude 模式还可搜索地图。操作前请解锁手机。" size:15];
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
    UIButton *keyButton = [self button:@"配置 Claude Key" color:UIColor.systemIndigoColor action:@selector(configureKeyTapped)];
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
    self.feedbackLabel = [self label:@"" size:15];
    self.feedbackLabel.textColor = UIColor.systemTealColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        heading, hint, self.taskField, self.clearButton, self.voiceButton, self.modelControl, keyButton, self.startButton,
        self.stopButton, hotkeyRow, self.stateLabel, self.detailLabel, self.feedbackLabel]];
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
        [keyButton.heightAnchor constraintEqualToConstant:42],
        [self.startButton.heightAnchor constraintEqualToConstant:48],
        [self.stopButton.heightAnchor constraintEqualToConstant:48],
    ]];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.8 target:self selector:@selector(refreshStatus)
                                               userInfo:nil repeats:YES];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
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
    unlink(BBHotkeyVoiceFile);
    if (pending && !self.recording) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{ if (!self.recording) [self voiceTapped]; });
    }
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
    if (!task.length) { self.feedbackLabel.text = @"请输入文字指令"; return; }
    self.feedbackLabel.text = @"";
    self.startButton.enabled = NO;
    [self request:@{@"op": @"start", @"task": task,
                    @"model": self.modelControl.selectedSegmentIndex == 1 ? @"claude" : @"mock"}];
}

- (void)stopTapped { [self request:@{@"op": @"stop"}]; }

- (void)clearTapped { self.taskField.text = @""; [self.taskField resignFirstResponder]; }

- (void)configureKeyTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"配置 Claude Key"
        message:@"Key 保存在本机，调用 Claude 时用于请求 Anthropic。请勿把 Key 写进任务文字。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"sk-ant-…";
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *key = [alert.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        weakSelf.feedbackLabel.text = BBSaveClaudeKey(key) ? @"Claude Key 已保存在本机" : @"Key 格式或保存失败";
        alert.textFields.firstObject.text = @"";
    }]];
    [self presentViewController:alert animated:YES completion:nil];
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
