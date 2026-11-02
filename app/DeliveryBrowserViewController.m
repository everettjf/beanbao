#import "DeliveryBrowserViewController.h"
#import "AgentClient.h"
#import <WebKit/WebKit.h>

@interface BBDeliveryBrowserViewController () <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextField *goalField;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, copy) NSString *deliveryTaskID;
@property(nonatomic, copy) NSString *deliveryServiceID;
@property(nonatomic, copy) NSString *deliveryGoal;
@property(nonatomic) NSUInteger completedSteps;
@property(nonatomic) BOOL runningDelivery;
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
        [[UIBarButtonItem alloc] initWithTitle:@"Check" style:UIBarButtonItemStylePlain
                                       target:self action:@selector(checkPage)],
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

    self.goalField = [UITextField new];
    self.goalField.borderStyle = UITextBorderStyleRoundedRect;
    self.goalField.placeholder = @"What would you like to order?";
    self.goalField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.goalField.returnKeyType = UIReturnKeyDone;
    [self.goalField addTarget:self action:@selector(deliveryGoalReturn)
             forControlEvents:UIControlEventEditingDidEndOnExit];
    self.goalField.translatesAutoresizingMaskIntoConstraints = NO;

    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"Run" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(toggleDeliveryRun)
             forControlEvents:UIControlEventTouchUpInside];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *commandBar = [[UIStackView alloc] initWithArrangedSubviews:
        @[self.goalField, self.runButton]];
    commandBar.axis = UILayoutConstraintAxisHorizontal;
    commandBar.spacing = 8;
    commandBar.alignment = UIStackViewAlignmentCenter;
    commandBar.translatesAutoresizingMaskIntoConstraints = NO;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = YES;
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.webView addObserver:self forKeyPath:@"URL" options:NSKeyValueObservingOptionNew context:NULL];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(deliveryAppDidBackground:)
        name:UIApplicationDidEnterBackgroundNotification object:nil];

    [self.view addSubview:self.statusLabel];
    [self.view addSubview:self.webView];
    [self.view addSubview:commandBar];
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.statusLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [self.statusLabel.heightAnchor constraintEqualToConstant:42],
        [self.webView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor constraintEqualToAnchor:self.statusLabel.bottomAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:commandBar.topAnchor constant:-4],
        [commandBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [commandBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [commandBar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-4],
        [commandBar.heightAnchor constraintEqualToConstant:44],
        [self.runButton.widthAnchor constraintEqualToConstant:50]
    ]];
    [self.webView loadRequest:[NSURLRequest requestWithURL:
        [NSURL URLWithString:@"https://www.ubereats.com/"]]];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.webView removeObserver:self forKeyPath:@"URL"];
    self.webView.navigationDelegate = nil;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if ((self.isMovingFromParentViewController || self.isBeingDismissed) && self.runningDelivery)
        [self toggleDeliveryRun];
}

- (void)deliveryAppDidBackground:(NSNotification *)notification {
    (void)notification;
    if (self.runningDelivery) [self toggleDeliveryRun];
}

- (void)updatePageStatus {
    if (self.runningDelivery) return;
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

- (void)deliveryGoalReturn { [self.goalField resignFirstResponder]; }

- (void)finishDeliveryRun:(NSString *)message {
    self.runningDelivery = NO;
    self.goalField.enabled = YES;
    [self.runButton setTitle:@"Run" forState:UIControlStateNormal];
    self.statusLabel.text = message;
}

- (void)markDeliveryStepUncertain:(NSString *)message {
    NSString *taskID = self.deliveryTaskID;
    NSString *serviceID = self.deliveryServiceID;
    if (taskID.length && serviceID.length) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBAgentRequest(@{@"op": @"stop", @"task_id": taskID,
                             @"service_id": serviceID});
        });
    }
    [self finishDeliveryRun:message];
}

- (void)toggleDeliveryRun {
    if (self.runningDelivery) {
        self.runningDelivery = NO;
        NSString *taskID = self.deliveryTaskID;
        NSString *serviceID = self.deliveryServiceID;
        if (taskID.length && serviceID.length) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                BBAgentRequest(@{@"op": @"stop", @"task_id": taskID,
                                 @"service_id": serviceID});
            });
        }
        [self finishDeliveryRun:@"Delivery run stopped."];
        return;
    }
    NSString *goal = [self.goalField.text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (goal.length < 2 || goal.length > 220 ||
        [goal rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
        self.statusLabel.text = @"Enter a short delivery request first.";
        return;
    }
    if (![self.deliveryGoal isEqualToString:goal]) self.deliveryTaskID = nil;
    self.deliveryGoal = goal;
    self.completedSteps = 0;
    self.runningDelivery = YES;
    self.goalField.enabled = NO;
    [self.goalField resignFirstResponder];
    [self.runButton setTitle:@"Stop" forState:UIControlStateNormal];
    [self planNextDeliveryStep];
}

- (void)planNextDeliveryStep {
    if (!self.runningDelivery) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self finishDeliveryRun:@"Return to BeanBao to continue the delivery run."];
        return;
    }
    if ([self.webView.URL.host.lowercaseString isEqualToString:@"auth.uber.com"]) {
        [self finishDeliveryRun:@"Sign in on Uber Eats, then tap Run to continue."];
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"Planning step %lu…",
                             (unsigned long)(self.completedSteps + 1)];
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!self.runningDelivery) return;
        if (!snapshot) {
            [self finishDeliveryRun:@"The current page cannot be planned safely."];
            return;
        }
        NSMutableDictionary *request = [@{@"op": @"delivery_plan", @"task": self.deliveryGoal,
                                         @"snapshot": snapshot} mutableCopy];
        if (self.deliveryTaskID.length) request[@"workflow_id"] = self.deliveryTaskID;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBAgentRequest(request);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.runningDelivery) return;
                if (![reply[@"ok"] boolValue] ||
                    ![reply[@"task_id"] isKindOfClass:NSString.class] ||
                    ![reply[@"service_id"] isKindOfClass:NSString.class]) {
                    [self finishDeliveryRun:reply[@"error"] ?: @"Could not plan this delivery step."];
                    return;
                }
                self.deliveryTaskID = reply[@"task_id"];
                self.deliveryServiceID = reply[@"service_id"];
                [self pollDeliveryStep:0];
            });
        });
    }];
}

- (void)pollDeliveryStep:(NSUInteger)attempt {
    if (!self.runningDelivery) return;
    if (attempt >= 135) {
        [self finishDeliveryRun:@"Delivery planning timed out. Check Sessions before retrying."];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"status"});
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.runningDelivery) return;
            if (![reply[@"ok"] boolValue] ||
                ![reply[@"task_id"] isEqualToString:self.deliveryTaskID] ||
                ![reply[@"service_id"] isEqualToString:self.deliveryServiceID]) {
                [self finishDeliveryRun:@"The delivery session changed. Run again to continue."];
                return;
            }
            NSString *phase = reply[@"phase"];
            if ([phase isEqualToString:@"running"]) {
                [self pollDeliveryStep:attempt + 1];
            } else if ([phase isEqualToString:@"waiting_for_user"] &&
                       [reply[@"delivery_action"] isKindOfClass:NSDictionary.class]) {
                [self runDeliveryAction:reply[@"delivery_action"]];
            } else {
                if ([phase isEqualToString:@"error"]) self.deliveryTaskID = nil;
                [self finishDeliveryRun:reply[@"message"] ?: @"Delivery step did not complete."];
            }
        });
    });
}

- (void)runDeliveryAction:(NSDictionary *)action {
    if (!self.runningDelivery) return;
    NSString *name = action[@"action"];
    if ([name isEqualToString:@"choose_option"]) {
        [self finishDeliveryRun:@"Choose the item option on Uber Eats, then tap Run again."];
        self.deliveryTaskID = nil;
        return;
    }
    self.statusLabel.text = [NSString stringWithFormat:@"Checking %@…", name ?: @"step"];
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!self.runningDelivery) return;
        if (!snapshot) {
            [self finishDeliveryRun:@"The page changed before this step. Run again to replan."];
            return;
        }
        NSDictionary *request = @{@"op": @"delivery_verify_action",
                                  @"task_id": self.deliveryTaskID,
                                  @"service_id": self.deliveryServiceID,
                                  @"snapshot": snapshot};
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBAgentRequest(request);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.runningDelivery) return;
                if (![reply[@"ok"] boolValue] || ![reply[@"valid"] boolValue]) {
                    [self finishDeliveryRun:@"The page or step changed. Run again to replan."];
                    return;
                }
                if ([name isEqualToString:@"review_checkout"]) {
                    [self finishDeliveryRun:@"Checkout reached. Review the exact total yourself. No order placed."];
                    return;
                }
                [self executeDeliveryAction:action onSnapshot:snapshot];
            });
        });
    }];
}

- (void)executeDeliveryAction:(NSDictionary *)action onSnapshot:(NSDictionary *)snapshot {
    if (!self.runningDelivery ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        [self markDeliveryStepUncertain:@"Return to BeanBao and review this delivery step."];
        return;
    }
    NSDictionary *payload = @{@"url": snapshot[@"url"],
                              @"text": snapshot[@"visible_text"],
                              @"action": action[@"action"],
                              @"target": action[@"target"]};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *literal = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    if (!literal || literal.length > 30000) {
        [self markDeliveryStepUncertain:@"The page is too large to act on safely."];
        return;
    }
    NSString *script = [NSString stringWithFormat:@"(() => {"
        "const p=%@;"
        "if(location.href!==p.url || !document.body || document.body.innerText.slice(0,20000)!==p.text) return {ok:false,error:'Page changed'};"
        "if(document.querySelector('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')) return {ok:false,error:'Sign-in page'};"
        "const clean=s=>(s||'').replace(/\\s+/g,' ').trim();"
        "const visible=e=>{const r=e.getBoundingClientRect();return r.width>0&&r.height>0};"
        "if(p.action==='search'){"
        "const inputs=[...document.querySelectorAll('input')].filter(e=>visible(e)&&['text','search'].includes(e.type)&&/search/i.test((e.placeholder||'')+' '+(e.getAttribute('aria-label')||'')));"
        "if(inputs.length!==1)return {ok:false,error:'Search field not unique'};"
        "const e=inputs[0];let formURL=null;"
        "if(e.form){formURL=new URL(e.form.action||location.href,location.href);if(formURL.host!==location.host||!['/','/feed','/search'].includes(formURL.pathname))return {ok:false,error:'Search form changed'};}"
        "const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;setter.call(e,p.target);"
        "e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));"
        "if(e.form)e.form.requestSubmit();else e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));"
        "return {ok:true};}"
        "if(!['open_merchant','open_item','add_to_cart','open_checkout'].includes(p.action))return {ok:false,error:'Unsupported action'};"
        "let wanted=p.target;"
        "if(p.action==='add_to_cart')wanted='ADD_TO_CART';"
        "if(p.action==='open_checkout')wanted='Go to checkout';"
        "const matches=new Set();"
        "for(const e of document.querySelectorAll('a,button,[role=button],label,span,h1,h2,h3,p,div')){"
        "if(!visible(e))continue;const t=clean(e.textContent);"
        "if(wanted==='ADD_TO_CART'?!/^Add \\d+ to order$/.test(t):t!==wanted)continue;"
        "const control=e.closest('a,button,[role=button],label');if(control&&visible(control))matches.add(control);}"
        "if(matches.size!==1)return {ok:false,error:'Action target not unique'};"
        "const control=[...matches][0];"
        "if(control.tagName==='A'){const link=new URL(control.href,location.href);if(link.protocol!=='https:'||!['www.ubereats.com','ubereats.com'].includes(link.host))return {ok:false,error:'Link outside Uber Eats'};}"
        "control.click();return {ok:true};})()", literal];
    self.statusLabel.text = [NSString stringWithFormat:@"Running %@…", action[@"action"]];
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!self.runningDelivery) return;
        if (error || ![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
            [self markDeliveryStepUncertain:@"The step may be incomplete. Check the page before retrying."];
            return;
        }
        [self verifyDeliveryTransitionFrom:snapshot attempt:0];
    }];
}

- (void)verifyDeliveryTransitionFrom:(NSDictionary *)before attempt:(NSUInteger)attempt {
    if (!self.runningDelivery) return;
    if (attempt >= 8) {
        [self markDeliveryStepUncertain:@"The page did not confirm this step. Check the cart before retrying."];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.runningDelivery) return;
        NSURL *url = self.webView.URL;
        if ([url.host.lowercaseString isEqualToString:@"auth.uber.com"]) {
            NSDictionary *login = @{@"url": url.absoluteString ?: @"",
                                    @"visible_text": @"",
                                    @"bundle_id": @"dev.beanbao.app",
                                    @"observed_at": @(NSDate.date.timeIntervalSince1970)};
            [self finishVerifiedDeliverySnapshot:login login:YES];
            return;
        }
        [self captureCurrentPageWithCompletion:^(NSDictionary *after) {
            if (!self.runningDelivery) return;
            BOOL changed = after &&
                (![after[@"url"] isEqualToString:before[@"url"]] ||
                 ![after[@"visible_text"] isEqualToString:before[@"visible_text"]]);
            if (!changed) {
                [self verifyDeliveryTransitionFrom:before attempt:attempt + 1];
                return;
            }
            [self finishVerifiedDeliverySnapshot:after login:NO];
        }];
    });
}

- (void)finishVerifiedDeliverySnapshot:(NSDictionary *)snapshot login:(BOOL)login {
    if (!self.runningDelivery) return;
    NSDictionary *request = @{@"op": @"delivery_action_result",
                              @"task_id": self.deliveryTaskID,
                              @"service_id": self.deliveryServiceID,
                              @"snapshot": snapshot};
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(request);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.runningDelivery) return;
            if (![reply[@"ok"] boolValue]) {
                [self finishDeliveryRun:@"The step outcome needs review. Check Uber Eats before retrying."];
                return;
            }
            self.completedSteps++;
            if (login) {
                [self finishDeliveryRun:@"Sign in on Uber Eats, then tap Run to continue."];
            } else if (self.completedSteps >= 8) {
                [self finishDeliveryRun:@"Eight steps reached. Review the page, then tap Run to continue."];
            } else {
                [self planNextDeliveryStep];
            }
        });
    });
}

- (void)checkPage {
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!snapshot) {
            if ([self.webView.URL.host.lowercaseString isEqualToString:@"auth.uber.com"]) {
                [self updatePageStatus];
            } else {
                self.statusLabel.text = @"This page is unavailable for BeanBao review.";
            }
            return;
        }
        NSString *checkedURL = snapshot[@"url"];
        self.statusLabel.text = @"Checking the current page…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBAgentRequest(@{@"op": @"delivery_observe", @"snapshot": snapshot});
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self.webView.URL.absoluteString isEqualToString:checkedURL]) return;
                if (![reply[@"ok"] boolValue]) {
                    self.statusLabel.text = reply[@"error"] ?: @"Could not check this page.";
                    return;
                }
                NSString *page = reply[@"page"];
                NSDictionary<NSString *, NSString *> *messages = @{
                    @"feed": @"Uber Eats home. Search for a restaurant or item.",
                    @"search": @"Search results. Choose a restaurant.",
                    @"merchant": @"Restaurant menu. Choose an item.",
                    @"item_configuration": @"Item options are open. Review them before adding.",
                    @"cart": @"Cart detected. Review items before checkout.",
                    @"checkout": @"Checkout detected. BeanBao has not verified or placed this order.",
                    @"login_required": @"Sign in on Uber Eats to continue.",
                    @"unsupported": @"This page is outside the supported delivery flow."
                };
                self.statusLabel.text = messages[page] ?: @"This page is outside the supported delivery flow.";
            });
        });
    }];
}

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
    NSString *script = @"(() => { if (document.querySelector('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')) return ''; const text = document.body && document.body.innerText; return typeof text === 'string' ? text.slice(0, 20000) : ''; })()";
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
