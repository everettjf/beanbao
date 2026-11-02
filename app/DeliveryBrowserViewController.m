#import "DeliveryBrowserViewController.h"
#import <WebKit/WebKit.h>

@interface BBDeliveryBrowserViewController () <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UILabel *statusLabel;
@end

@implementation BBDeliveryBrowserViewController

static BOOL BBTrustedDeliveryHost(NSString *host) {
    NSString *name = host.lowercaseString ?: @"";
    return [name isEqualToString:@"uber.com"] || [name hasSuffix:@".uber.com"] ||
        [name isEqualToString:@"ubereats.com"] || [name hasSuffix:@".ubereats.com"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Food delivery";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Safari" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(openSafari)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                       target:self action:@selector(reloadPage)]
    ];

    self.statusLabel = [UILabel new];
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"Loading Uber Eats…";
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.webView addObserver:self forKeyPath:@"URL" options:NSKeyValueObservingOptionNew context:NULL];

    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.webView];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [self.statusLabel.heightAnchor constraintEqualToConstant:42],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self.webView loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.ubereats.com/"]]];
}

- (void)dealloc {
    [self.webView removeObserver:self forKeyPath:@"URL"];
    self.webView.navigationDelegate = nil;
}

- (void)updatePageStatus {
    NSURL *url = self.webView.URL;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"auth.uber.com"]) {
        self.statusLabel.text = @"Sign in on Uber Eats to continue. BeanBao does not read this page.";
    } else if ([host isEqualToString:@"www.ubereats.com"] &&
               [url.path isEqualToString:@"/checkout"]) {
        self.statusLabel.text = @"Checkout review. No order will be placed by BeanBao.";
    } else if ([host isEqualToString:@"www.ubereats.com"]) {
        self.statusLabel.text = @"Browse menus and build a cart. Review the final total before ordering.";
    } else {
        self.statusLabel.text = @"Waiting for an Uber Eats page…";
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context {
    (void)change; (void)context;
    if (object == self.webView && [keyPath isEqualToString:@"URL"]) {
        [self updatePageStatus];
        return;
    }
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}

- (void)reloadPage { [self.webView reload]; }

- (void)openSafari {
    NSURL *url = self.webView.URL;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        !BBTrustedDeliveryHost(url.host)) return;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = action.request.URL;
    BOOL secure = [url.scheme.lowercaseString isEqualToString:@"https"];
    if (!action.targetFrame) {
        decisionHandler(WKNavigationActionPolicyCancel);
    } else if ((action.targetFrame.isMainFrame && secure && BBTrustedDeliveryHost(url.host)) ||
               (!action.targetFrame.isMainFrame &&
                (secure || [url.absoluteString isEqualToString:@"about:blank"]))) {
        decisionHandler(WKNavigationActionPolicyAllow);
    } else {
        self.statusLabel.text = @"This link leaves Uber Eats. Open it in Safari if needed.";
        decisionHandler(WKNavigationActionPolicyCancel);
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    (void)webView; (void)navigation;
    [self updatePageStatus];
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation
       withError:(NSError *)error {
    (void)webView; (void)navigation; (void)error;
    self.statusLabel.text = @"Uber Eats could not load here. Use Safari to continue.";
}

- (void)captureCurrentPageWithCompletion:(void (^)(NSDictionary *snapshot))completion {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self captureCurrentPageWithCompletion:completion]; });
        return;
    }
    NSURL *url = self.webView.URL;
    if (![url.scheme.lowercaseString isEqualToString:@"https"] ||
        ![url.host.lowercaseString isEqualToString:@"www.ubereats.com"]) {
        completion(nil);
        return;
    }
    NSString *expectedURL = url.absoluteString;
    NSString *script = @"(() => { if (document.querySelector('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')) return ''; const text = document.body && document.body.innerText; return typeof text === 'string' ? text.slice(0, 30000) : ''; })()";
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (error || ![result isKindOfClass:NSString.class] || ![(NSString *)result length] ||
            ![self.webView.URL.absoluteString isEqualToString:expectedURL]) {
            completion(nil);
            return;
        }
        completion(@{@"url": expectedURL,
                     @"visible_text": result,
                     @"bundle_id": @"dev.beanbao.app",
                     @"observed_at": @(NSDate.date.timeIntervalSince1970)});
    }];
}

@end
