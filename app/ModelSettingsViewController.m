#import "ModelSettingsViewController.h"
#import "ModelConfig.h"
#import "AgentClient.h"

@interface BBModelSettingsViewController () <UITextFieldDelegate>
@property(nonatomic, strong) UISegmentedControl *providerControl;
@property(nonatomic, strong) UITextField *modelField;
@property(nonatomic, strong) UITextField *endpointField;
@property(nonatomic, strong) UITextField *keyField;
@property(nonatomic, strong) UIStackView *endpointGroup;
@property(nonatomic, strong) UILabel *keyStatus;
@property(nonatomic, strong) UILabel *message;
@property(nonatomic, strong) NSDictionary *config;
@property(nonatomic, strong) NSMutableDictionary *drafts;
@property(nonatomic, copy) NSString *lastProvider;
@end

@implementation BBModelSettingsViewController

- (UILabel *)label:(NSString *)text size:(CGFloat)size color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = [UIFont systemFontOfSize:size];
    label.textColor = color;
    label.numberOfLines = 0;
    return label;
}

- (UITextField *)field:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *field = [UITextField new];
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont systemFontOfSize:16];
    field.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.secureTextEntry = secure;
    field.returnKeyType = UIReturnKeyDone;
    field.delegate = self;
    [field.heightAnchor constraintEqualToConstant:48].active = YES;
    return field;
}

- (UIStackView *)fieldGroup:(NSString *)title field:(UITextField *)field {
    UILabel *label = [self label:title size:14 color:UIColor.secondaryLabelColor];
    UIStackView *group = [[UIStackView alloc] initWithArrangedSubviews:@[label, field]];
    group.axis = UILayoutConstraintAxisVertical;
    group.spacing = 8;
    return group;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"模型服务";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.config = BBModelLoad();
    self.drafts = [NSMutableDictionary dictionary];
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    UILabel *intro = [self label:@"选择你自己的模型服务。BeanBao 只在需要理解地图界面时请求模型；打开 App 和新建备忘录仍在手机上完成。"
                            size:15 color:UIColor.secondaryLabelColor];
    self.providerControl = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"OpenAI", @"兼容 API"]];
    [self.providerControl addTarget:self action:@selector(providerChanged) forControlEvents:UIControlEventValueChanged];
    self.modelField = [self field:@"例如 claude-sonnet-5-5" secure:NO];
    self.endpointField = [self field:@"https://example.com/v1" secure:NO];
    self.endpointField.keyboardType = UIKeyboardTypeURL;
    self.endpointGroup = [self fieldGroup:@"接口地址（HTTPS）" field:self.endpointField];
    self.keyField = [self field:@"输入新 Key；留空则保留原 Key" secure:YES];
    self.keyStatus = [self label:@"" size:13 color:UIColor.secondaryLabelColor];
    self.message = [self label:@"" size:14 color:UIColor.systemRedColor];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"保存模型设置" forState:UIControlStateNormal];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.backgroundColor = UIColor.systemIndigoColor;
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    save.layer.cornerRadius = 14;
    [save.heightAnchor constraintEqualToConstant:52].active = YES;
    [save addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    UILabel *privacy = [self label:@"Key 只保存在这台手机。兼容 API 使用 OpenAI Chat Completions 格式，请选择支持图片输入的模型。界面含疑似凭据时，任务会停止。"
                              size:13 color:UIColor.tertiaryLabelColor];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        intro, self.providerControl, [self fieldGroup:@"模型名称" field:self.modelField],
        self.endpointGroup, [self fieldGroup:@"API Key" field:self.keyField],
        self.keyStatus, save, self.message, privacy]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:28],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    NSString *selected = self.config[@"provider"];
    self.providerControl.selectedSegmentIndex = [selected isEqualToString:@"openai"] ? 1 :
        ([selected isEqualToString:@"compatible"] ? 2 : 0);
    self.lastProvider = selected;
    [self showSelectedProfile];
}

- (NSString *)selectedProvider {
    return @[@"claude", @"openai", @"compatible"][self.providerControl.selectedSegmentIndex];
}

- (void)showSelectedProfile {
    NSString *provider = [self selectedProvider];
    NSDictionary *profile = self.drafts[provider] ?: BBModelProfile(self.config, provider);
    self.modelField.text = profile[@"model"];
    self.endpointField.text = profile[@"endpoint"];
    self.endpointGroup.hidden = ![provider isEqualToString:@"compatible"];
    self.keyField.text = @"";
    self.keyStatus.text = BBModelReadKey(provider) ? @"这项服务的 Key 已保存在手机上" : @"尚未配置这项服务的 Key";
    self.message.text = @"";
}

- (void)providerChanged {
    if (self.lastProvider.length) self.drafts[self.lastProvider] = @{
        @"model": self.modelField.text ?: @"", @"endpoint": self.endpointField.text ?: @""};
    self.lastProvider = [self selectedProvider];
    [self showSelectedProfile];
}

- (void)saveTapped {
    NSDictionary *status = BBAgentRequest(@{@"op": @"status"});
    if ([status[@"running"] boolValue]) {
        self.message.textColor = UIColor.systemRedColor;
        self.message.text = @"任务运行中，请完成或停止后再切换模型";
        return;
    }
    NSString *error = nil;
    BOOL okay = BBModelSave([self selectedProvider], self.modelField.text,
                            self.endpointField.text, self.keyField.text, &error);
    self.keyField.text = @"";
    if (!okay) {
        self.message.textColor = UIColor.systemRedColor;
        self.message.text = error ?: @"保存失败";
        return;
    }
    self.config = BBModelLoad();
    [self.drafts removeObjectForKey:[self selectedProvider]];
    self.message.textColor = UIColor.systemGreenColor;
    [self showSelectedProfile];
    self.message.text = @"已保存。新任务将使用此模型服务。";
    if (self.onSave) self.onSave();
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
@end
