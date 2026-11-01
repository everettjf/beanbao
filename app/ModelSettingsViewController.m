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
    self.title = @"Model services";
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
    UILabel *intro = [self label:@"Choose a model service. BeanBao calls it only when it needs to understand Maps. Opening apps and creating notes happen on your phone."
                            size:15 color:UIColor.secondaryLabelColor];
    self.providerControl = [[UISegmentedControl alloc] initWithItems:@[@"Claude", @"OpenAI", @"Compatible API"]];
    [self.providerControl addTarget:self action:@selector(providerChanged) forControlEvents:UIControlEventValueChanged];
    self.modelField = [self field:@"e.g. claude-sonnet-5-5" secure:NO];
    self.endpointField = [self field:@"https://example.com/v1" secure:NO];
    self.endpointField.keyboardType = UIKeyboardTypeURL;
    self.endpointGroup = [self fieldGroup:@"API endpoint (HTTPS)" field:self.endpointField];
    self.keyField = [self field:@"New API key (optional)" secure:YES];
    self.keyStatus = [self label:@"" size:13 color:UIColor.secondaryLabelColor];
    self.message = [self label:@"" size:14 color:UIColor.systemRedColor];
    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setTitle:@"Save model settings" forState:UIControlStateNormal];
    [save setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    save.backgroundColor = UIColor.systemIndigoColor;
    save.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    save.layer.cornerRadius = 14;
    [save.heightAnchor constraintEqualToConstant:52].active = YES;
    [save addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    UILabel *privacy = [self label:@"Keys stay on this phone. Compatible APIs use the OpenAI Chat Completions format and require a model that accepts images. Tasks stop when credentials may be visible."
                              size:13 color:UIColor.secondaryLabelColor];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        intro, self.providerControl, [self fieldGroup:@"Model name" field:self.modelField],
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
    self.keyStatus.text = BBModelReadKey(provider) ? @"A key is saved for this service" : @"No key saved for this service";
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
        self.message.text = @"Finish or stop the current task before changing models";
        return;
    }
    NSString *error = nil;
    BOOL okay = BBModelSave([self selectedProvider], self.modelField.text,
                            self.endpointField.text, self.keyField.text, &error);
    self.keyField.text = @"";
    if (!okay) {
        self.message.textColor = UIColor.systemRedColor;
        self.message.text = error ?: @"Could not save settings";
        return;
    }
    self.config = BBModelLoad();
    [self.drafts removeObjectForKey:[self selectedProvider]];
    self.message.textColor = UIColor.systemGreenColor;
    [self showSelectedProfile];
    self.message.text = @"Saved. New tasks will use this service.";
    if (self.onSave) self.onSave();
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}
@end
