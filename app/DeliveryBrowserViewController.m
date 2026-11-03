#import "DeliveryBrowserViewController.h"
#import "AgentClient.h"
#import <WebKit/WebKit.h>

@interface BBDeliveryBrowserViewController () <WKNavigationDelegate>
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UITextField *goalField;
@property(nonatomic, strong) UIButton *runButton;
@property(nonatomic, strong) UIBarButtonItem *reviewButton;
@property(nonatomic, strong) UIBarButtonItem *checkButton;
@property(nonatomic, strong) UIBarButtonItem *safariButton;
@property(nonatomic, strong) UIBarButtonItem *reloadButton;
@property(nonatomic, copy) NSString *deliveryTaskID;
@property(nonatomic, copy) NSString *deliveryServiceID;
@property(nonatomic, copy) NSString *deliveryGoal;
@property(nonatomic) NSUInteger completedSteps;
@property(nonatomic) NSUInteger pageReplans;
@property(nonatomic) BOOL runningDelivery;
@property(nonatomic) BOOL orderAttemptInFlight;
@property(nonatomic) BOOL orderOutcomePending;
@property(nonatomic, copy) NSString *captureFailure;
@end

@implementation BBDeliveryBrowserViewController

static BOOL BBTrustedDeliveryHost(NSString *host) {
    NSString *name = host.lowercaseString ?: @"";
    return [name isEqualToString:@"uber.com"] || [name hasSuffix:@".uber.com"] ||
        [name isEqualToString:@"ubereats.com"] || [name hasSuffix:@".ubereats.com"];
}

static NSDictionary *BBDeliveryRequest(NSDictionary *request) {
    NSDictionary *reply = BBAgentRequest(request);
    // Agent restarts invalidate the browser's in-memory pairing token.
    // The loopback rejection stays generic; the browser gives a recovery step.
    if ([reply[@"error"] isEqualToString:@"Invalid request"])
        return @{@"ok": @NO, @"error":
            @"Web connection needs refreshing. Open BeanBao and tap BeanBao Web again."};
    return reply;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Food delivery";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.reviewButton = [[UIBarButtonItem alloc] initWithTitle:@"Review"
        style:UIBarButtonItemStylePlain target:self action:@selector(reviewOrder)];
    self.checkButton = [[UIBarButtonItem alloc] initWithTitle:@"Check"
        style:UIBarButtonItemStylePlain target:self action:@selector(checkPage)];
    self.safariButton = [[UIBarButtonItem alloc] initWithTitle:@"Safari"
        style:UIBarButtonItemStylePlain target:self action:@selector(openSafari)];
    self.reloadButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(reloadPage)];
    [self setReviewAvailable:NO];

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
    self.goalField.clearButtonMode = UITextFieldViewModeWhileEditing;
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

- (void)setReviewAvailable:(BOOL)available {
    self.reviewButton.enabled = available;
    self.navigationItem.rightBarButtonItems = available ?
        @[self.reviewButton, self.reloadButton] :
        @[self.checkButton, self.safariButton, self.reloadButton];
}

- (void)updatePageStatus {
    if (self.runningDelivery || self.orderAttemptInFlight || self.orderOutcomePending) return;
    NSURL *url = self.webView.URL;
    NSString *host = url.host.lowercaseString;
    if ([host isEqualToString:@"auth.uber.com"]) {
        [self setReviewAvailable:NO];
        self.statusLabel.text = @"Sign in on Uber Eats to continue. BeanBao does not read this page.";
    } else if ([host isEqualToString:@"www.ubereats.com"] &&
               [url.path isEqualToString:@"/checkout"]) {
        self.statusLabel.text = @"Checkout is visible. Review the exact total before placing an order.";
    } else if ([host isEqualToString:@"www.ubereats.com"]) {
        [self setReviewAvailable:NO];
        self.statusLabel.text = @"Browse menus and build a cart. Review the final total before ordering.";
    } else {
        [self setReviewAvailable:NO];
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

- (void)replanAfterPageChange {
    if (!self.runningDelivery) return;
    if (self.pageReplans >= 3) {
        [self finishDeliveryRun:@"The page kept changing. Check it, then tap Run to continue."];
        return;
    }
    self.pageReplans++;
    self.statusLabel.text = @"Page updated. Rechecking before the next step…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self.runningDelivery) [self planNextDeliveryStep];
    });
}

- (void)markDeliveryStepUncertain:(NSString *)message {
    NSString *taskID = self.deliveryTaskID;
    NSString *serviceID = self.deliveryServiceID;
    if (taskID.length && serviceID.length) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBDeliveryRequest(@{@"op": @"stop", @"task_id": taskID,
                             @"service_id": serviceID});
        });
    }
    [self finishDeliveryRun:message];
}

- (void)toggleDeliveryRun {
    if (self.orderAttemptInFlight || self.orderOutcomePending) return;
    if (self.runningDelivery) {
        self.runningDelivery = NO;
        NSString *taskID = self.deliveryTaskID;
        NSString *serviceID = self.deliveryServiceID;
        if (taskID.length && serviceID.length) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                BBDeliveryRequest(@{@"op": @"stop", @"task_id": taskID,
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
    [self setReviewAvailable:NO];
    self.deliveryGoal = goal;
    self.completedSteps = 0;
    self.pageReplans = 0;
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
            if ([self.captureFailure isEqualToString:@"empty"] ||
                [self.captureFailure isEqualToString:@"changed"]) {
                [self replanAfterPageChange];
                return;
            }
            NSString *message = [self.captureFailure isEqualToString:@"credentials"] ?
                @"Sign-in fields are visible. Finish sign-in yourself, then tap Run." :
                ([self.captureFailure isEqualToString:@"empty"] ?
                 @"Uber Eats has not loaded this page. Refresh it before retrying." :
                 ([self.captureFailure isEqualToString:@"changed"] ?
                  @"The page changed while BeanBao read it. Tap Run to retry." :
                  @"The current page cannot be planned safely."));
            [self finishDeliveryRun:message];
            return;
        }
        NSString *pageText = snapshot[@"visible_text"];
        if ([pageText containsString:@"Enter delivery address"] &&
            ![pageText containsString:@"Search Uber Eats"]) {
            [self finishDeliveryRun:@"Set a delivery address on Uber Eats, then tap Run again."];
            return;
        }
        NSMutableDictionary *request = [@{@"op": @"delivery_plan", @"task": self.deliveryGoal,
                                         @"snapshot": snapshot} mutableCopy];
        if (self.deliveryTaskID.length) request[@"workflow_id"] = self.deliveryTaskID;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBDeliveryRequest(request);
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
        NSDictionary *reply = BBDeliveryRequest(@{@"op": @"status"});
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
    self.statusLabel.text = [NSString stringWithFormat:@"Checking %@…", name ?: @"step"];
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!self.runningDelivery) return;
        if (!snapshot) {
            if ([self.captureFailure isEqualToString:@"empty"] ||
                [self.captureFailure isEqualToString:@"changed"]) {
                [self replanAfterPageChange];
            } else {
                [self finishDeliveryRun:@"The page changed before this step. Check it before retrying."];
            }
            return;
        }
        NSDictionary *request = @{@"op": @"delivery_verify_action",
                                  @"task_id": self.deliveryTaskID,
                                  @"service_id": self.deliveryServiceID,
                                  @"snapshot": snapshot};
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBDeliveryRequest(request);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.runningDelivery) return;
                if (![reply[@"ok"] boolValue]) {
                    [self finishDeliveryRun:reply[@"error"] ?: @"The step changed. Check it before retrying."];
                    return;
                }
                if (![reply[@"valid"] boolValue]) {
                    [self replanAfterPageChange];
                    return;
                }
                if ([name isEqualToString:@"review_options"]) {
                    self.deliveryTaskID = nil;
                    [self finishDeliveryRun:@"Item options are ready. Review them here; no item was added to the cart."];
                    return;
                }
                if ([name isEqualToString:@"review_cart"]) {
                    self.deliveryTaskID = nil;
                    [self finishDeliveryRun:@"Cart is ready for review. No checkout or order was started."];
                    return;
                }
                if ([name isEqualToString:@"review_checkout"]) {
                    [self setReviewAvailable:YES];
                    [self finishDeliveryRun:@"Checkout reviewed. Tap Review order to inspect every charge before placing it."];
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
                              @"selected": snapshot[@"selected_options"] ?: @[],
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
        "if(location.href!==p.url || !document.body || (p.action!=='open_cart'&&document.body.innerText.slice(0,20000)!==p.text)) return {ok:false,error:'Page changed'};"
        "const clean=s=>(s||'').replace(/\\s+/g,' ').trim();"
        "const rendered=e=>{const r=e.getBoundingClientRect();const s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0};"
        "const visible=e=>{const r=e.getBoundingClientRect();return rendered(e)&&r.top>=0&&r.left>=0&&r.top<window.innerHeight&&r.left<window.innerWidth};"
        "const reachable=e=>{if(!visible(e))return false;const r=e.getBoundingClientRect(),x=Math.max(0,Math.min(window.innerWidth-1,r.left+r.width/2)),y=Math.max(0,Math.min(window.innerHeight-1,r.top+r.height/2)),hit=document.elementFromPoint(x,y);return hit&&(hit===e||e.contains(hit))};"
        "const selected=()=>{const labels=[...document.querySelectorAll('label[for]')];return [...new Set([...document.querySelectorAll('input[type=radio]:checked,input[type=checkbox]:checked')].map(e=>labels.find(l=>l.htmlFor===e.id)).filter(l=>l&&rendered(l)).map(l=>clean(l.textContent)).filter(Boolean))]};"
        "if(JSON.stringify(selected())!==JSON.stringify(p.selected))return {ok:false,error:'Page changed'};"
        "if([...document.querySelectorAll('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')].some(rendered))return {ok:false,error:'Sign-in page'};"
        "if(p.action==='open_search'){const matches=new Set();for(const e of document.querySelectorAll('a,button,[role=button],label,span,div')){if(!visible(e)||clean(e.textContent)!=='Search Uber Eats')continue;const c=e.closest('a,button,[role=button],label')||e;if(visible(c))matches.add(c)}if(matches.size!==1)return {ok:false,error:'Search control not unique'};[...matches][0].click();return {ok:true};}"
        "if(p.action==='search'){"
        "const inputs=[...document.querySelectorAll('input')].filter(e=>['text','search'].includes(e.type)&&visible(e)&&clean(e.placeholder)==='Search Uber Eats'&&e.getAttribute('aria-hidden')!=='true'&&!e.disabled&&(()=>{const r=e.getBoundingClientRect();const hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);return hit===e||e.contains(hit)})());"
        "if(inputs.length!==1)return {ok:false,error:'Search field not unique'};"
        "const e=inputs[0];let formURL=null;"
        "if(e.form){formURL=new URL(e.form.action||location.href,location.href);if(formURL.host!==location.host||!['/','/feed','/search-suggestions','/search'].includes(formURL.pathname))return {ok:false,error:'Search form changed'};}"
        "const setter=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set;setter.call(e,p.target);"
        "e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));"
        "if(e.form)e.form.requestSubmit();else e.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',bubbles:true}));"
        "return {ok:true};}"
        "if(p.action==='choose_option'){const candidates=[...document.querySelectorAll('label[for]')].filter(e=>clean(e.textContent)===p.target).map(e=>({label:e,input:document.getElementById(e.htmlFor)})).filter(x=>x.input&&x.input.type==='radio'&&!x.input.checked&&x.input.name&&rendered(x.label));"
        "if(!candidates.length)return {ok:false,error:'Option changed'};"
        "if(candidates.length!==1)return {ok:false,error:'Option target not unique'};"
        "const e=candidates[0].label;if(!reachable(e))e.scrollIntoView({block:'center',behavior:'instant'});"
        "if(!reachable(e))return {ok:false,error:'Option changed'};"
        "e.click();return {ok:true};}"
        "if(!['open_merchant','open_item','add_to_cart','open_cart','open_checkout'].includes(p.action))return {ok:false,error:'Unsupported action'};"
        "if(p.action==='add_to_cart'){const buttons=[...document.querySelectorAll('button[data-testid=add-to-cart-button]')].filter(e=>/^Add \\d+ to order$/.test(clean(e.getAttribute('aria-label')))&&reachable(e)&&!e.disabled);if(buttons.length!==1)return {ok:false,error:'Action target not unique'};buttons[0].click();return {ok:true}}"
        "if(p.action==='open_cart'){const links=[...document.querySelectorAll('a[data-testid=view-cart-button]')].filter(e=>e.getAttribute('aria-label')==='VIEW CART'&&reachable(e)&&(()=>{const u=new URL(e.href,location.href);return u.protocol==='https:'&&u.host===location.host&&u.pathname==='/cart'})());if(links.length!==1)return {ok:false,error:'Action target not unique'};links[0].click();return {ok:true}}"
        "let wanted=p.target;"
        "if(p.action==='open_checkout')wanted='Go to checkout';"
        "const matches=new Map();"
        "for(const e of document.querySelectorAll('a,button,[role=button],label,span,h1,h2,h3,p,div')){"
        "if(!visible(e))continue;const t=clean(e.textContent);"
        "if(t!==wanted)continue;"
        "const control=e.closest('a,button,[role=button],label');if(!control||!visible(control))continue;"
        "if(p.action==='open_merchant'&&(control.tagName!=='A'||!control.href||!new URL(control.href,location.href).pathname.startsWith('/store/')))continue;"
        "const key=p.action==='open_merchant'&&control.tagName==='A'?new URL(control.href,location.href).pathname:"
        "p.action==='open_item'&&control.tagName==='A'?control.href:control;matches.set(key,control)}"
        "if(matches.size!==1)return {ok:false,error:'Action target not unique'};"
        "const control=[...matches.values()][0];"
        "if(control.tagName==='A'){const link=new URL(control.href,location.href);if(link.protocol!=='https:'||!['www.ubereats.com','ubereats.com'].includes(link.host))return {ok:false,error:'Link outside Uber Eats'};}"
        "control.click();return {ok:true};})()", literal];
    self.statusLabel.text = [NSString stringWithFormat:@"Running %@…", action[@"action"]];
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        if (!self.runningDelivery) return;
        if (error || ![result isKindOfClass:NSDictionary.class] || ![result[@"ok"] boolValue]) {
            if (error || ![result isKindOfClass:NSDictionary.class]) {
                // A navigation may interrupt WebKit's callback after the click.
                // Reconcile against the expected next page before calling it uncertain.
                [self verifyDeliveryTransitionFrom:snapshot action:action attempt:0];
                return;
            }
            NSString *reason = [result isKindOfClass:NSDictionary.class] ? result[@"error"] : nil;
            NSSet *known = [NSSet setWithArray:@[@"Page changed", @"Sign-in page",
                @"Search control not unique",
                @"Search field not unique", @"Search form changed", @"Action target not unique",
                @"Option target not unique", @"Option changed",
                @"Link outside Uber Eats", @"Unsupported action"]];
            NSString *message = [reason isKindOfClass:NSString.class] && [known containsObject:reason] ?
                [NSString stringWithFormat:@"Step paused: %@. Check the page before retrying.", reason] :
                @"The step may be incomplete. Check the page before retrying.";
            if (!error && self.deliveryTaskID.length && self.deliveryServiceID.length &&
                [reason isKindOfClass:NSString.class] && [known containsObject:reason]) {
                NSString *taskID = self.deliveryTaskID;
                NSString *serviceID = self.deliveryServiceID;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    NSDictionary *reply = BBDeliveryRequest(@{@"op": @"delivery_action_aborted",
                        @"task_id": taskID, @"service_id": serviceID, @"reason": reason});
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self.runningDelivery) return;
                        if ([reply[@"ok"] boolValue]) {
                            self.deliveryTaskID = nil;
                            [self finishDeliveryRun:message];
                        } else {
                            [self markDeliveryStepUncertain:message];
                        }
                    });
                });
                return;
            }
            [self markDeliveryStepUncertain:message];
            return;
        }
        [self verifyDeliveryTransitionFrom:snapshot action:action attempt:0];
    }];
}

- (void)verifyDeliveryTransitionFrom:(NSDictionary *)before action:(NSDictionary *)action
                              attempt:(NSUInteger)attempt {
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
                                    @"bundle_id": @"dev.beanbao.deliverybrowser",
                                    @"observed_at": @(NSDate.date.timeIntervalSince1970)};
            [self finishVerifiedDeliverySnapshot:login login:YES];
            return;
        }
        [self captureCurrentPageWithCompletion:^(NSDictionary *after) {
            if (!self.runningDelivery) return;
            BOOL changed = after &&
                (![after[@"url"] isEqualToString:before[@"url"]] ||
                 ![after[@"visible_text"] isEqualToString:before[@"visible_text"]] ||
                 ![after[@"selected_options"] isEqual:before[@"selected_options"]]);
            NSString *name = action[@"action"];
            NSString *text = [after[@"visible_text"] isKindOfClass:NSString.class] ?
                after[@"visible_text"] : @"";
            NSString *path = [NSURL URLWithString:after[@"url"] ?: @""].path ?: @"";
            BOOL expected = NO;
            if ([name isEqualToString:@"open_search"]) {
                expected = [path isEqualToString:@"/search-suggestions"];
            } else if ([name isEqualToString:@"search"]) {
                expected = [path isEqualToString:@"/search"];
            } else if ([name isEqualToString:@"open_merchant"]) {
                expected = [path hasPrefix:@"/store/"] &&
                    [text containsString:@"Featured items"];
            } else if ([name isEqualToString:@"open_item"] ||
                       [name isEqualToString:@"choose_option"]) {
                expected = [path hasPrefix:@"/store/"] &&
                    [text rangeOfString:@"Add [0-9]+ to order"
                                   options:NSRegularExpressionSearch].location != NSNotFound;
                if ([name isEqualToString:@"choose_option"]) {
                    expected = expected && [after[@"selected_options"]
                        containsObject:action[@"target"]];
                }
            } else if ([name isEqualToString:@"add_to_cart"]) {
                expected = [path hasPrefix:@"/store/"] &&
                    [text containsString:@"View order"];
            } else if ([name isEqualToString:@"open_cart"]) {
                expected = ([path isEqualToString:@"/cart"] ||
                            [path isEqualToString:@"/cart/"]) &&
                    [text containsString:@"Go to checkout"];
            } else if ([name isEqualToString:@"open_checkout"]) {
                expected = [path isEqualToString:@"/checkout"] ||
                    [path isEqualToString:@"/checkout/"];
            }
            if (!changed || !expected) {
                [self verifyDeliveryTransitionFrom:before action:action attempt:attempt + 1];
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
        NSDictionary *reply = BBDeliveryRequest(request);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.runningDelivery) return;
            if (![reply[@"ok"] boolValue]) {
                [self reconcileDeliveryActionReceiptForTask:self.deliveryTaskID
                                                      service:self.deliveryServiceID
                                                        login:login attempt:0];
                return;
            }
            [self continueAfterVerifiedDeliveryAction:login];
        });
    });
}

- (void)reconcileDeliveryActionReceiptForTask:(NSString *)taskID
                                       service:(NSString *)serviceID
                                         login:(BOOL)login attempt:(NSUInteger)attempt {
    if (!self.runningDelivery) return;
    if (attempt >= 3) {
        [self finishDeliveryRun:@"The step outcome needs review. Check Uber Eats before retrying."];
        return;
    }
    self.statusLabel.text = @"Checking the saved result of this step…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *status = BBDeliveryRequest(@{@"op": @"status"});
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.runningDelivery) return;
            if ([status[@"ok"] boolValue] &&
                [status[@"task_id"] isEqualToString:taskID] &&
                [status[@"service_id"] isEqualToString:serviceID] &&
                [status[@"phase"] isEqualToString:@"waiting_for_user"] &&
                [status[@"message"] isEqualToString:@"Delivery step verified"] &&
                !status[@"delivery_action"]) {
                [self continueAfterVerifiedDeliveryAction:login];
            } else if ([status[@"phase"] isEqualToString:@"executing"] &&
                       [status[@"task_id"] isEqualToString:taskID] &&
                       [status[@"service_id"] isEqualToString:serviceID]) {
                [self reconcileDeliveryActionReceiptForTask:taskID service:serviceID
                                                      login:login attempt:attempt + 1];
            } else {
                [self finishDeliveryRun:@"The step outcome needs review. Check Uber Eats before retrying."];
            }
        });
    });
}

- (void)continueAfterVerifiedDeliveryAction:(BOOL)login {
    if (!self.runningDelivery) return;
    self.completedSteps++;
    self.pageReplans = 0;
    if (login) {
        [self finishDeliveryRun:@"Sign in on Uber Eats, then tap Run to continue."];
    } else if (self.completedSteps >= 8) {
        [self finishDeliveryRun:@"Eight steps reached. Review the page, then tap Run to continue."];
    } else {
        [self planNextDeliveryStep];
    }
}

static NSString *BBOrderMoney(NSNumber *minor) {
    long long amount = [minor longLongValue];
    unsigned long long magnitude = amount < 0 ? (unsigned long long)(-amount) :
        (unsigned long long)amount;
    return [NSString stringWithFormat:@"%@$%llu.%02llu", amount < 0 ? @"-" : @"",
        magnitude / 100, magnitude % 100];
}

static NSString *BBOrderReviewText(NSDictionary *summary) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithArray:@[
        [NSString stringWithFormat:@"Merchant: %@", summary[@"merchant"] ?: @""],
        [NSString stringWithFormat:@"Deliver to: %@", summary[@"address"] ?: @""], @""]];
    for (NSDictionary *item in summary[@"items"]) {
        [lines addObject:[NSString stringWithFormat:@"%@ × %@  %@", item[@"quantity"],
            item[@"name"], BBOrderMoney(item[@"lineTotalMinor"])]];
        for (NSString *option in item[@"options"])
            [lines addObject:[NSString stringWithFormat:@"  %@", option]];
    }
    [lines addObject:@""];
    for (NSArray *entry in @[@[@"Subtotal", @"subtotal_minor"], @[@"Tax", @"tax_minor"],
                             @[@"Delivery fee", @"delivery_fee_minor"],
                             @[@"Service fee", @"service_fee_minor"], @[@"Tip", @"tip_minor"]])
        [lines addObject:[NSString stringWithFormat:@"%@: %@", entry[0],
            BBOrderMoney(summary[entry[1]])]];
    for (NSDictionary *adjustment in summary[@"adjustments"])
        [lines addObject:[NSString stringWithFormat:@"%@: %@", adjustment[@"name"],
            BBOrderMoney(adjustment[@"amountMinor"])]];
    [lines addObject:[NSString stringWithFormat:@"Total: %@ %@",
        summary[@"currency"] ?: @"", BBOrderMoney(summary[@"total_minor"])]];
    [lines addObject:@"\nPlacing this order can charge your account. BeanBao will make only one attempt. If the result is unclear, check Uber Eats order history before trying again."];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)dismissOrderReview {
    [self.presentedViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)reviewOrder {
    if (self.runningDelivery || self.orderAttemptInFlight ||
        !self.deliveryTaskID.length || !self.deliveryServiceID.length) return;
    NSString *taskID = self.deliveryTaskID;
    NSString *serviceID = self.deliveryServiceID;
    [self setReviewAvailable:NO];
    self.statusLabel.text = @"Loading the checked order summary…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBDeliveryRequest(@{@"op": @"delivery_checkout_summary",
            @"task_id": taskID, @"service_id": serviceID});
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![taskID isEqualToString:self.deliveryTaskID] ||
                ![serviceID isEqualToString:self.deliveryServiceID]) return;
            NSDictionary *summary = reply[@"summary"];
            NSString *digest = summary[@"cart_digest"];
            if (![reply[@"ok"] boolValue] || ![summary isKindOfClass:NSDictionary.class] ||
                ![digest isKindOfClass:NSString.class] || digest.length != 64) {
                self.statusLabel.text = reply[@"error"] ?: @"The checkout review is unavailable.";
                return;
            }
            [self setReviewAvailable:YES];
            UIViewController *page = [UIViewController new];
            page.title = @"Review order";
            page.view.backgroundColor = UIColor.systemBackgroundColor;
            page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
                initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self
                action:@selector(dismissOrderReview)];
            UITextView *details = [UITextView new];
            details.editable = NO;
            details.selectable = YES;
            details.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
            details.text = BBOrderReviewText(summary);
            details.translatesAutoresizingMaskIntoConstraints = NO;
            UIButton *confirm = [UIButton buttonWithType:UIButtonTypeSystem];
            [confirm setTitle:[NSString stringWithFormat:@"Place order · %@",
                BBOrderMoney(summary[@"total_minor"])] forState:UIControlStateNormal];
            confirm.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
            [confirm setTitleColor:UIColor.systemRedColor forState:UIControlStateNormal];
            confirm.translatesAutoresizingMaskIntoConstraints = NO;
            __weak typeof(self) weakSelf = self;
            __weak UIButton *weakConfirm = confirm;
            [confirm addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
                (void)action;
                __strong typeof(weakSelf) self = weakSelf;
                if (!self) return;
                weakConfirm.enabled = NO;
                [self dismissViewControllerAnimated:YES completion:^{
                    [self beginApprovedOrderWithDigest:digest];
                }];
            }] forControlEvents:UIControlEventTouchUpInside];
            [page.view addSubview:details];
            [page.view addSubview:confirm];
            [NSLayoutConstraint activateConstraints:@[
                [details.topAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.topAnchor constant:12],
                [details.leadingAnchor constraintEqualToAnchor:page.view.leadingAnchor constant:18],
                [details.trailingAnchor constraintEqualToAnchor:page.view.trailingAnchor constant:-18],
                [details.bottomAnchor constraintEqualToAnchor:confirm.topAnchor constant:-12],
                [confirm.leadingAnchor constraintEqualToAnchor:page.view.leadingAnchor constant:24],
                [confirm.trailingAnchor constraintEqualToAnchor:page.view.trailingAnchor constant:-24],
                [confirm.bottomAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.bottomAnchor constant:-12],
                [confirm.heightAnchor constraintEqualToConstant:52]
            ]];
            UINavigationController *navigation = [[UINavigationController alloc]
                initWithRootViewController:page];
            navigation.modalPresentationStyle = UIModalPresentationPageSheet;
            [self presentViewController:navigation animated:YES completion:nil];
        });
    });
}

- (void)beginApprovedOrderWithDigest:(NSString *)digest {
    if (self.runningDelivery || self.orderAttemptInFlight ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.orderAttemptInFlight = YES;
    [self setReviewAvailable:NO];
    self.runButton.enabled = NO;
    self.statusLabel.text = @"Checking the current checkout before placing the order…";
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!snapshot) {
            self.orderAttemptInFlight = NO;
            self.runButton.enabled = YES;
            self.statusLabel.text = @"Checkout changed. Review it again; no order was placed.";
            return;
        }
        NSString *taskID = self.deliveryTaskID;
        NSString *serviceID = self.deliveryServiceID;
        NSDictionary *request = @{@"op": @"delivery_order_begin", @"task_id": taskID,
            @"service_id": serviceID, @"cart_digest": digest, @"snapshot": snapshot};
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBDeliveryRequest(request);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![reply[@"ok"] boolValue] ||
                    ![reply[@"task_id"] isEqualToString:taskID] ||
                    ![reply[@"service_id"] isEqualToString:serviceID]) {
                    self.orderAttemptInFlight = NO;
                    self.runButton.enabled = YES;
                    self.statusLabel.text = reply[@"error"] ?:
                        @"Order status is uncertain. Check Uber Eats before trying again.";
                    return;
                }
                self.orderOutcomePending = YES;
                [self clickApprovedOrderOnSnapshot:snapshot];
            });
        });
    }];
}

- (void)clickApprovedOrderOnSnapshot:(NSDictionary *)snapshot {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        self.statusLabel.text = @"Order action paused. Check Uber Eats order history before retrying.";
        self.orderAttemptInFlight = NO;
        self.runButton.enabled = NO;
        return;
    }
    NSDictionary *payload = @{@"url": snapshot[@"url"], @"text": snapshot[@"visible_text"]};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *literal = [[NSString alloc] initWithData:encoded encoding:NSUTF8StringEncoding];
    if (!literal || literal.length > 30000) {
        self.statusLabel.text = @"Checkout page is too large. Check Uber Eats before retrying.";
        self.orderAttemptInFlight = NO;
        self.runButton.enabled = NO;
        return;
    }
    NSString *orderScript = [NSString stringWithFormat:@"(() => {"
        "const p=%@;"
        "if(location.href!==p.url||!/^https:\\/\\/www\\.ubereats\\.com\\/checkout\\/?(?:\\?.*)?$/.test(location.href)||!document.body||document.body.innerText.slice(0,20000)!==p.text)return {ok:false,error:'Page changed'};"
        "const clean=s=>(s||'').replace(/\\s+/g,' ').trim();"
        "const visible=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&r.top>=0&&r.left>=0&&r.top<innerHeight&&r.left<innerWidth&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0};"
        "if([...document.querySelectorAll('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')].some(visible))return {ok:false,error:'Sign-in page'};"
        "const controls=[...new Set([...document.querySelectorAll('button,[role=button]')].filter(e=>visible(e)&&!e.disabled&&clean(e.textContent)==='Place order'))];"
        "if(controls.length!==1)return {ok:false,error:'Place order control changed'};"
        "const e=controls[0],r=e.getBoundingClientRect(),hit=document.elementFromPoint(r.left+r.width/2,r.top+r.height/2);"
        "if(!(hit===e||e.contains(hit)))return {ok:false,error:'Place order control covered'};"
        "e.click();return {ok:true};})()", literal];
    [self.webView evaluateJavaScript:orderScript completionHandler:^(id result, NSError *error) {
        self.orderAttemptInFlight = NO;
        self.runButton.enabled = NO;
        NSDictionary *reply = [result isKindOfClass:NSDictionary.class] ? result : nil;
        self.statusLabel.text = !error && [reply[@"ok"] boolValue] ?
            @"One order attempt was sent. Check Uber Eats for confirmation; BeanBao will not retry it." :
            @"Order result is uncertain. Check Uber Eats order history before trying again.";
    }];
}

- (void)checkPage {
    [self captureCurrentPageWithCompletion:^(NSDictionary *snapshot) {
        if (!snapshot) {
            if ([self.webView.URL.host.lowercaseString isEqualToString:@"auth.uber.com"]) {
                [self updatePageStatus];
            } else if ([self.captureFailure isEqualToString:@"credentials"]) {
                self.statusLabel.text = @"Sign-in fields are visible. BeanBao will not read this page.";
            } else if ([self.captureFailure isEqualToString:@"empty"]) {
                self.statusLabel.text = @"Uber Eats has not loaded this page. Try Refresh.";
            } else {
                self.statusLabel.text = @"This page is unavailable for BeanBao review.";
            }
            return;
        }
        NSString *checkedURL = snapshot[@"url"];
        self.statusLabel.text = @"Checking the current page…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSDictionary *reply = BBDeliveryRequest(@{@"op": @"delivery_observe", @"snapshot": snapshot});
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![self.webView.URL.absoluteString isEqualToString:checkedURL]) return;
                if (![reply[@"ok"] boolValue]) {
                    self.statusLabel.text = reply[@"error"] ?: @"Could not check this page.";
                    return;
                }
                NSString *page = reply[@"page"];
                if ([page isEqualToString:@"unsupported"] &&
                    [NSURL URLWithString:checkedURL].host.lowercaseString.length) {
                    NSURL *siteURL = [NSURL URLWithString:checkedURL];
                    self.statusLabel.text = [NSString stringWithFormat:
                        @"Unsupported Uber Eats page: %@", siteURL.path ?: @"/"];
                    return;
                }
                NSDictionary<NSString *, NSString *> *messages = @{
                    @"feed": @"Uber Eats home. Search for a restaurant or item.",
                    @"search_suggestions": @"Search input ready. Enter a restaurant or item.",
                    @"search": @"Search results. Choose a restaurant.",
                    @"merchant": @"Restaurant menu. Choose an item.",
                    @"item_configuration": @"Item options are open. Review them before adding.",
                    @"cart_handoff": @"Item added. Open the cart to verify its options.",
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
        self.captureFailure = @"unsupported";
        completion(nil);
        return;
    }
    NSString *expectedURL = url.absoluteString;
    NSString *script = @"(() => {"
        "if(!document.body)return {reason:'empty'};"
        "const sensitive=[...document.querySelectorAll('input[type=password],input[type=email],input[type=tel],input[autocomplete=one-time-code]')].some(e=>{const r=e.getBoundingClientRect();const s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0});"
        "if(sensitive)return {reason:'credentials'};"
        "const text=document.body.innerText;"
        "const clean=s=>(s||'').replace(/\\s+/g,' ').trim();"
        "const rendered=e=>{const r=e.getBoundingClientRect(),s=getComputedStyle(e);return r.width>0&&r.height>0&&s.display!=='none'&&s.visibility!=='hidden'&&Number(s.opacity)!==0};"
        "const labels=[...document.querySelectorAll('label[for]')];"
        "const selected=[...new Set([...document.querySelectorAll('input[type=radio]:checked,input[type=checkbox]:checked')].map(e=>labels.find(l=>l.htmlFor===e.id)).filter(l=>l&&rendered(l)).map(l=>clean(l.textContent)).filter(Boolean))];"
        "const available=[...new Set(labels.filter(rendered).map(e=>clean(e.textContent)).filter(Boolean))];"
        "if(selected.length>30||selected.some(s=>s.length>120))return {reason:'invalid'};"
        "if(available.length>60||available.some(s=>s.length>120))return {reason:'invalid'};"
        "return typeof text==='string'&&text.length?{text:text.slice(0,20000),selected:selected,available:available}:{reason:'empty'}"
        "})()";
    [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
        NSDictionary *reply = [result isKindOfClass:NSDictionary.class] ? result : nil;
        NSString *text = [reply[@"text"] isKindOfClass:NSString.class] ? reply[@"text"] : nil;
        NSArray *selected = [reply[@"selected"] isKindOfClass:NSArray.class] ? reply[@"selected"] : nil;
        NSArray *available = [reply[@"available"] isKindOfClass:NSArray.class] ? reply[@"available"] : nil;
        if (error || !text.length || !selected || !available ||
            ![self.webView.URL.absoluteString isEqualToString:expectedURL]) {
            self.captureFailure = ![self.webView.URL.absoluteString isEqualToString:expectedURL] ?
                @"changed" : ([reply[@"reason"] isEqualToString:@"credentials"] ?
                               @"credentials" : @"empty");
            completion(nil);
            return;
        }
        self.captureFailure = nil;
        completion(@{@"url": expectedURL,
                     @"visible_text": text,
                     @"selected_options": selected,
                     @"available_options": available,
                     @"bundle_id": @"dev.beanbao.deliverybrowser",
                     @"observed_at": @(NSDate.date.timeIntervalSince1970)});
    }];
}

@end
