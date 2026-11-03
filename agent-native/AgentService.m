#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <spawn.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <limits.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import "BBAudit.h"
#import "ModelConfig.h"

extern char **environ;
extern void BBReleaseWakeLease(void);
extern int32_t BBMarkResearchMailQueued(const char *workflowID);
extern int32_t BBMarkAppStoreInstalled(const char *workflowID, const char *bundleID);
extern char *BBUberEatsClassifySnapshot(const char *snapshotJSON);
extern char *BBUberEatsValidateAction(const char *snapshotJSON, const char *actionJSON);
extern int32_t BBDeliveryActionBegin(const char *workflowID, const char *actionJSON);
extern int32_t BBDeliveryActionFinish(const char *workflowID, const char *actionJSON,
                                     const char *snapshotJSON);
extern int32_t BBDeliveryActionAbort(const char *workflowID, const char *actionJSON);
extern int32_t BBDeliveryReadOnlyReviewFinish(const char *workflowID, const char *actionJSON,
                                             const char *snapshotJSON);

static const char *BBServiceSocket = "/var/mobile/Library/Caches/BeanBao/agent.sock";
static const uint16_t BBBrowserPort = 47813;
static NSString *BBBrowserPairingToken;
static NSString *BBWorkflowRoot = @"/var/mobile/Library/Application Support/BeanBao/workflows";

@interface BBServiceState : NSObject
@property(nonatomic) pid_t child;
@property(nonatomic) NSUInteger generation;
@property(nonatomic, copy) NSString *phase;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy) NSString *app;
@property(nonatomic, copy) NSString *serviceID;
@property(nonatomic, copy) NSString *taskID;
@property(nonatomic, copy) NSString *reportPath;
@property(nonatomic, copy) NSString *mailDraftPath;
@property(nonatomic, copy) NSString *appCandidatePath;
@property(nonatomic, strong) NSDictionary *deliveryAction;
@property(nonatomic) BOOL stopping;
@end
@implementation BBServiceState
@end

static BBServiceState *BBState;

static BOOL BBIsNoteTask(NSString *task) {
    return [task hasPrefix:@"新建备忘录："] && task.length >= 10 && task.length <= 166 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound;
}

static NSString *BBCompletionMessage(NSString *task) {
    if ([task.lowercaseString containsString:@"pdf"] &&
        ([task.lowercaseString hasPrefix:@"research "] || [task hasPrefix:@"调研"]))
        return @"PDF report created";
    if ([task hasPrefix:@"在地图搜索"]) return @"Maps search completed";
    if (BBIsNoteTask(task)) return @"Note created";
    return @"Target app is in the foreground";
}

BOOL BBResearchPDFCandidate(NSString *task) {
    if (![task isKindOfClass:NSString.class] || task.length < 12 || task.length > 220 ||
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound)
        return NO;
    NSString *lower = task.lowercaseString;
    NSRegularExpression *researchVerb = [NSRegularExpression
        regularExpressionWithPattern:@"\\b(?:research|investigate|compare|analy[sz]e|study|survey|explore)\\b|\\blook into\\b"
        options:NSRegularExpressionCaseInsensitive error:nil];
    BOOL research = [researchVerb firstMatchInString:task options:0
        range:NSMakeRange(0, task.length)] != nil ||
        [task containsString:@"调研"] || [task containsString:@"研究"] ||
        [task containsString:@"比较"] || [task containsString:@"分析"];
    BOOL pdf = [lower containsString:@"pdf"];
    NSRegularExpression *negated = [NSRegularExpression
        regularExpressionWithPattern:@"\\b(?:do not|don't|never)\\b.{0,40}\\b(?:research|investigate|compare|analy[sz]e|study|survey|explore|create|make|write|generate|pdf)\\b"
        options:NSRegularExpressionCaseInsensitive error:nil];
    if ([negated firstMatchInString:task options:0 range:NSMakeRange(0, task.length)] ||
        (([task containsString:@"不要"] || [task hasPrefix:@"别"] ||
          [task containsString:@"请别"] || [task containsString:@"，别"]) &&
         ([task containsString:@"调研"] || [task containsString:@"研究"] ||
          [task containsString:@"生成"] || [task containsString:@"制作"]))) return NO;
    NSRegularExpression *otherAction = [NSRegularExpression
        regularExpressionWithPattern:@"(?:^\\s*|[,;&.]\\s*|\\b(?:and|then|also)\\s+)(?:install|download|order|buy|purchase|pay|delete|remove|open|launch|find|post|share|change|edit|set|update|toggle|enable|disable|turn|call|navigate|route|message|send\\s+(?:a\\s+)?(?:message|text))\\b"
        options:NSRegularExpressionCaseInsensitive error:nil];
    BOOL unrelated = [otherAction firstMatchInString:task options:0
        range:NSMakeRange(0, task.length)] != nil;
    for (NSString *phrase in @[@"并安装", @"然后安装", @"再安装", @"并下载", @"然后下载", @"再下载",
                               @"并下单", @"然后下单", @"再下单", @"并打开", @"然后打开", @"再打开",
                               @"并发送消息", @"然后发送消息", @"再发送消息"])
        if ([task containsString:phrase]) unrelated = YES;
    BOOL externalAction = [lower containsString:@"email"] || [lower containsString:@"mail to"] ||
        [lower containsString:@"send "] || [task containsString:@"邮件"] ||
        [task containsString:@"发送"];
    NSRegularExpression *recipient = [NSRegularExpression
        regularExpressionWithPattern:@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"
        options:NSRegularExpressionCaseInsensitive error:nil];
    BOOL hasRecipient = [recipient firstMatchInString:task options:0
                                                range:NSMakeRange(0, task.length)] != nil;
    return research && pdf && !unrelated && (!externalAction || hasRecipient);
}

static BOOL BBIsResearchPDFTask(NSString *task) {
    NSString *lower = task.lowercaseString;
    return ([lower hasPrefix:@"research "] || [lower hasPrefix:@"investigate "] ||
            [task hasPrefix:@"调研"]) && BBResearchPDFCandidate(task);
}

BOOL BBResearchAppCandidate(NSString *task) {
    if (![task isKindOfClass:NSString.class] || task.length > 220) return NO;
    NSRegularExpression *suffix = [NSRegularExpression regularExpressionWithPattern:
        @"\\b(?:and|then)\\s+(?:(find|get)\\s+(?:the\\s+)?app\\s+|(install|download)\\s+(?:the\\s+)?(?:app\\s+)?)([A-Za-z0-9][A-Za-z0-9 .&'-]{1,79})\\s*[.!?]?\\s*$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [suffix firstMatchInString:task options:0
        range:NSMakeRange(0, task.length)];
    if (!match || match.range.location == NSNotFound) return NO;
    NSString *research = [[task substringToIndex:match.range.location]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    research = [research stringByTrimmingCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@",; "]];
    NSString *query = [[task substringWithRange:[match rangeAtIndex:3]]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .!?"]];
    NSString *lowerQuery = query.lowercaseString;
    NSString *lowerResearch = research.lowercaseString;
    return ([lowerResearch hasPrefix:@"research "] ||
            [lowerResearch hasPrefix:@"investigate "]) &&
        query.length >= 2 && query.length <= 80 &&
        [lowerQuery rangeOfString:@" and "].location == NSNotFound &&
        [lowerQuery rangeOfString:@" then "].location == NSNotFound &&
        BBResearchPDFCandidate(research);
}

static BOOL BBResearchAppInstallationCandidate(NSString *task) {
    if (!BBResearchAppCandidate(task)) return NO;
    NSRegularExpression *verb = [NSRegularExpression regularExpressionWithPattern:
        @"\\b(?:and|then)\\s+(?:(?:install|download)\\s+(?:the\\s+)?(?:app\\s+)?|get\\s+(?:the\\s+)?app\\s+)[A-Za-z0-9][A-Za-z0-9 .&'-]{1,79}\\s*[.!?]?\\s*$"
        options:NSRegularExpressionCaseInsensitive error:nil];
    return [verb firstMatchInString:task options:0 range:NSMakeRange(0, task.length)] != nil;
}

static BOOL BBIsAppStoreTask(NSString *task) {
    NSString *lower = task.lowercaseString;
    BOOL explicitAction = [lower hasPrefix:@"install "] || [lower hasPrefix:@"download "] ||
        [lower hasPrefix:@"find app "] || [lower hasPrefix:@"get app "] ||
        [task hasPrefix:@"下载应用"] || [task hasPrefix:@"安装应用"];
    return explicitAction && task.length > 10 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound &&
        [lower rangeOfString:@" and "].location == NSNotFound &&
        [task rangeOfString:@"并"].location == NSNotFound;
}

static NSString *BBWorkflowFolder(NSString *identity) {
    NSUUID *uuid = [identity isKindOfClass:NSString.class] ?
        [[NSUUID alloc] initWithUUIDString:identity] : nil;
    if (!uuid || ![uuid.UUIDString isEqualToString:identity]) return nil;
    return [BBWorkflowRoot stringByAppendingPathComponent:identity];
}

static NSDictionary *BBReadWorkflowRecord(NSString *identity) {
    NSString *folder = BBWorkflowFolder(identity);
    if (!folder) return nil;
    struct stat directory = {0};
    if (lstat(folder.fileSystemRepresentation, &directory) ||
        !S_ISDIR(directory.st_mode) || directory.st_uid != 501 ||
        (directory.st_mode & 077)) return nil;
    NSString *path = [folder stringByAppendingPathComponent:@"session.json"];
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != 501 ||
        (info.st_mode & 077) || info.st_size <= 0 || info.st_size > 4 * 1024 * 1024) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger remaining = data.length;
    uint8_t *cursor = data.mutableBytes;
    while (remaining) {
        ssize_t count = read(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        cursor += count; remaining -= (NSUInteger)count;
    }
    close(fd);
    NSDictionary *record = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![record isKindOfClass:NSDictionary.class] ||
        ![record[@"id"] isEqualToString:identity] ||
        ![record[@"request"] isKindOfClass:NSString.class] ||
        ![record[@"phase"] isKindOfClass:NSString.class]) return nil;
    return record;
}

static BOOL BBPrivateWorkflowFile(NSString *path, off_t minimum, off_t maximum) {
    struct stat info = {0};
    return !lstat(path.fileSystemRepresentation, &info) && S_ISREG(info.st_mode) &&
        info.st_uid == 501 && !(info.st_mode & 077) &&
        info.st_size >= minimum && info.st_size <= maximum;
}

static NSDictionary *BBReadAppCandidate(NSString *identity) {
    NSString *folder = BBWorkflowFolder(identity);
    if (!folder || !BBReadWorkflowRecord(identity)) return nil;
    NSString *path = [folder stringByAppendingPathComponent:@"app-candidate.json"];
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return nil;
    struct stat info = {0};
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != 501 ||
        (info.st_mode & 077) || info.st_size < 2 || info.st_size > 16 * 1024) {
        close(fd); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger remaining = data.length;
    uint8_t *cursor = data.mutableBytes;
    while (remaining) {
        ssize_t count = read(fd, cursor, remaining);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { close(fd); return nil; }
        cursor += count; remaining -= (NSUInteger)count;
    }
    close(fd);
    NSDictionary *candidate = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![candidate isKindOfClass:NSDictionary.class]) return nil;
    NSString *bundle = candidate[@"bundleID"];
    NSNumber *product = candidate[@"productID"];
    if (![bundle isKindOfClass:NSString.class] ||
        [bundle rangeOfString:@"^[A-Za-z0-9.-]{3,180}$" options:NSRegularExpressionSearch].location != 0 ||
        ![product isKindOfClass:NSNumber.class] || product.longLongValue <= 0) return nil;
    return candidate;
}

static BOOL BBInstalledBundleVerified(NSString *bundleID) {
    Class cls = objc_getClass("LSApplicationProxy");
    if (!cls) {
        // The Agent is a Foundation-only launchd process. Load the framework
        // that owns LaunchServices proxies before querying installed apps.
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_LAZY | RTLD_LOCAL);
        cls = objc_getClass("LSApplicationProxy");
    }
    SEL proxySelector = @selector(applicationProxyForIdentifier:);
    if (!cls || ![cls respondsToSelector:proxySelector]) return NO;
    @try {
        id proxy = ((id (*)(id, SEL, NSString *))objc_msgSend)((id)cls, proxySelector, bundleID);
        if (!proxy || ![proxy respondsToSelector:@selector(bundleIdentifier)] ||
            ![proxy respondsToSelector:@selector(bundleURL)]) return NO;
        NSString *actual = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleIdentifier));
        NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, @selector(bundleURL));
        if (![actual isEqualToString:bundleID] || ![url isKindOfClass:NSURL.class] ||
            !url.isFileURL) return NO;
        if ([proxy respondsToSelector:@selector(isPlaceholder)] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(proxy, @selector(isPlaceholder))) return NO;
        NSString *infoPath = [url.path stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        return [info[@"CFBundleIdentifier"] isEqualToString:bundleID];
    } @catch (__unused NSException *exception) { return NO; }
}

static BOOL BBIsDeliveryRecord(NSDictionary *record) {
    NSDictionary *operations = record[@"operations"];
    if (![operations isKindOfClass:NSDictionary.class]) return NO;
    for (NSString *key in operations)
        if ([key isKindOfClass:NSString.class] && [key hasPrefix:@"delivery-plan-v1-"]) return YES;
    return NO;
}

static BOOL BBWorkflowHasUnresolvedMutation(NSDictionary *record) {
    NSDictionary *operations = record[@"operations"];
    if (![operations isKindOfClass:NSDictionary.class]) return NO;
    for (NSDictionary *operation in operations.allValues) {
        if (![operation isKindOfClass:NSDictionary.class]) continue;
        NSString *state = operation[@"state"];
        if ([state isEqualToString:@"needsReconciliation"] ||
            ([state isEqualToString:@"running"] &&
             ![operation[@"effect"] isEqualToString:@"readOnly"])) return YES;
    }
    return NO;
}

static NSString *BBWorkflowEffectivePhase(NSDictionary *record) {
    return BBWorkflowHasUnresolvedMutation(record) ? @"needsReconciliation" : record[@"phase"];
}

static NSString *BBWorkflowKind(NSString *identity, NSDictionary *record) {
    if (BBIsDeliveryRecord(record)) return @"delivery";
    if (BBResearchAppCandidate(record[@"request"])) {
        NSDictionary *operations = record[@"operations"];
        for (NSDictionary *operation in operations.allValues)
            if ([operation isKindOfClass:NSDictionary.class] &&
                [operation[@"tool"] isEqualToString:@"mail_prepare"] &&
                [operation[@"state"] isEqualToString:@"completed"])
                return @"research_mail_app";
        return @"research_app";
    }
    return BBReadAppCandidate(identity) ? @"app_store" : @"research";
}

static BOOL BBDeliveryHasUnfinishedAction(NSDictionary *record) {
    NSDictionary *operations = record[@"operations"];
    if (![operations isKindOfClass:NSDictionary.class]) return NO;
    for (NSDictionary *operation in operations.allValues)
        if ([operation isKindOfClass:NSDictionary.class] &&
            [operation[@"tool"] isEqualToString:@"delivery_execute"] &&
            ![operation[@"state"] isEqualToString:@"completed"]) return YES;
    return NO;
}

static NSArray<NSDictionary *> *BBWorkflowSummaries(void) {
    struct stat root = {0};
    if (lstat(BBWorkflowRoot.fileSystemRepresentation, &root) ||
        !S_ISDIR(root.st_mode) || root.st_uid != 501 || (root.st_mode & 077)) return @[];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:BBWorkflowRoot error:nil] ?: @[];
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    for (NSString *identity in entries) {
        NSDictionary *record = BBReadWorkflowRecord(identity);
        if (!record) continue;
        NSNumber *updated = [record[@"updatedAt"] isKindOfClass:NSNumber.class] ?
            record[@"updatedAt"] : @0;
        NSString *request = record[@"request"];
        if (request.length > 220) continue;
        NSString *kind = BBWorkflowKind(identity, record);
        [items addObject:@{@"id": identity, @"request": request, @"kind": kind,
                           @"phase": BBWorkflowEffectivePhase(record),
                           @"install_requested": @(BBResearchAppInstallationCandidate(request)),
                           @"mail_queued": @([record[@"mailQueuedAt"] isKindOfClass:NSNumber.class]),
                           @"app_installed": @([record[@"installedAppBundleID"] isKindOfClass:NSString.class]),
                           @"updated_at": @([updated doubleValue] + 978307200.0)}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"updated_at"] compare:a[@"updated_at"]];
    }];
    if (items.count > 30) [items removeObjectsInRange:NSMakeRange(30, items.count - 30)];
    return items;
}

static NSString *BBDeliveryStepTitle(NSDictionary *result) {
    if (![result isKindOfClass:NSDictionary.class]) return @"Delivery step";
    NSString *action = result[@"action"];
    NSString *target = result[@"target"];
    if (![action isKindOfClass:NSString.class]) return @"Delivery step";
    NSDictionary<NSString *, NSString *> *plain = @{
        @"open_search": @"Open search", @"review_options": @"Review options",
        @"add_to_cart": @"Add item to cart", @"open_cart": @"Open cart",
        @"review_cart": @"Review cart", @"open_checkout": @"Open checkout",
        @"review_checkout": @"Review checkout"
    };
    if (plain[action]) return plain[action];
    NSDictionary<NSString *, NSString *> *targeted = @{
        @"search": @"Search for", @"open_merchant": @"Open merchant",
        @"open_item": @"Open item", @"choose_option": @"Choose option"
    };
    NSString *verb = targeted[action];
    if (!verb || ![target isKindOfClass:NSString.class] || !target.length || target.length > 80 ||
        [target rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return @"Delivery step";
    return [NSString stringWithFormat:@"%@: %@", verb, target];
}

static NSDictionary *BBWorkflowDetails(NSDictionary *request) {
    NSString *identity = request[@"workflow_id"];
    NSDictionary *record = BBReadWorkflowRecord(identity);
    if (!record) return @{@"ok": @NO, @"error": @"Workflow not found"};
    NSDictionary *operations = record[@"operations"];
    BOOL delivery = BBIsDeliveryRecord(record);
    NSMutableArray<NSDictionary *> *steps = [NSMutableArray array];
    if ([operations isKindOfClass:NSDictionary.class]) {
        for (NSString *key in operations) {
            NSDictionary *operation = operations[key];
            if (![operation isKindOfClass:NSDictionary.class]) continue;
            NSString *tool = operation[@"tool"];
            NSString *state = operation[@"state"];
            NSNumber *updated = operation[@"updatedAt"];
            if (![tool isKindOfClass:NSString.class] || !tool.length || tool.length > 64 ||
                ![@[@"running", @"completed", @"failed", @"needsReconciliation"] containsObject:state] ||
                ![updated isKindOfClass:NSNumber.class]) continue;
            NSString *title = nil;
            if (delivery && [tool isEqualToString:@"delivery_choose"] &&
                [key hasPrefix:@"delivery-plan-v1-"]) {
                NSString *suffix = [key substringFromIndex:@"delivery-plan-v1-".length];
                NSDictionary *receipt = operations[[@"delivery-execute-v1-" stringByAppendingString:suffix]] ?:
                    operations[[@"delivery-review-v1-" stringByAppendingString:suffix]];
                title = BBDeliveryStepTitle(operation[@"result"]);
                if ([receipt isKindOfClass:NSDictionary.class] &&
                    [@[@"running", @"completed", @"failed", @"needsReconciliation"]
                        containsObject:receipt[@"state"]] &&
                    [receipt[@"updatedAt"] isKindOfClass:NSNumber.class]) {
                    state = receipt[@"state"];
                    updated = receipt[@"updatedAt"];
                } else if ([state isEqualToString:@"completed"]) {
                    state = @"proposed";
                }
            } else if (delivery &&
                       ([@[@"delivery_execute", @"delivery_review_cart"] containsObject:tool])) {
                NSString *prefix = [tool isEqualToString:@"delivery_execute"] ?
                    @"delivery-execute-v1-" : @"delivery-review-v1-";
                if ([key hasPrefix:prefix]) {
                    NSString *planKey = [@"delivery-plan-v1-" stringByAppendingString:
                        [key substringFromIndex:prefix.length]];
                    if ([operations[planKey] isKindOfClass:NSDictionary.class]) continue;
                }
            }
            NSMutableDictionary *step = [@{@"tool": tool, @"state": state,
                @"updated_at": @([updated doubleValue] + 978307200.0)} mutableCopy];
            if (title) step[@"title"] = title;
            [steps addObject:step];
        }
    }
    [steps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"updated_at"] compare:b[@"updated_at"]];
    }];
    NSUInteger total = steps.count;
    if (steps.count > 40) [steps removeObjectsInRange:NSMakeRange(0, steps.count - 40)];
    NSString *kind = BBWorkflowKind(identity, record);
    return @{@"ok": @YES, @"id": identity, @"request": record[@"request"],
             @"kind": kind, @"phase": BBWorkflowEffectivePhase(record), @"steps": steps,
             @"total_steps": @(total)};
}

static void BBRestoreWorkflowIdentity(NSString *identity) {
    NSDictionary *record = BBReadWorkflowRecord(identity);
    if (!record) return;
    NSString *folder = BBWorkflowFolder(identity);
    if (!folder) return;
    BBState.taskID = identity;
    BBState.reportPath = nil;
    BBState.mailDraftPath = nil;
    BBState.appCandidatePath = nil;
    BBState.deliveryAction = nil;
    NSString *phase = BBWorkflowEffectivePhase(record);
    NSString *pdfPath = [folder stringByAppendingPathComponent:@"report.pdf"];
    NSString *draftPath = [folder stringByAppendingPathComponent:@"mail-draft.json"];
    NSString *candidatePath = [folder stringByAppendingPathComponent:@"app-candidate.json"];
    BOOL hasPDF = BBPrivateWorkflowFile(pdfPath, 100, 20 * 1024 * 1024);
    BOOL hasDraft = BBPrivateWorkflowFile(draftPath, 1, 16 * 1024);
    BOOL hasCandidate = BBPrivateWorkflowFile(candidatePath, 1, 16 * 1024);
    BOOL hasDelivery = BBIsDeliveryRecord(record);
    BOOL composite = BBResearchAppCandidate(record[@"request"]);
    BOOL installRequested = BBResearchAppInstallationCandidate(record[@"request"]);
    BOOL mailQueued = [record[@"mailQueuedAt"] isKindOfClass:NSNumber.class];
    BOOL appInstalled = [record[@"installedAppBundleID"] isKindOfClass:NSString.class];
    BBState.app = hasDelivery ? @"DeliveryPlan" :
        (composite ? @"ResearchAppStoreReview" :
         (hasCandidate ? @"AppStoreReview" :
          (hasDraft ? @"ResearchMailDraft" : @"ResearchPDF")));
    BBState.reportPath = hasPDF ? pdfPath : nil;
    if (hasDelivery && BBDeliveryHasUnfinishedAction(record)) {
        BBState.phase = @"needs_reconciliation";
        BBState.message = @"A delivery step may have changed the cart. Check Uber Eats before continuing.";
    } else if (BBWorkflowHasUnresolvedMutation(record)) {
        BBState.phase = @"needs_reconciliation";
        BBState.message = @"A workflow step may have changed its result. Review the saved session.";
    } else if (composite && !([@[@"planned", @"running", @"failed", @"cancelled"]
                          containsObject:phase]) && (!hasPDF || !hasCandidate)) {
        BBState.phase = @"error";
        BBState.message = @"A workflow artifact is missing. Review the saved session.";
        BBState.reportPath = nil;
    } else if ([phase isEqualToString:@"waitingForUser"] && hasDelivery) {
        BBState.phase = @"waiting_for_user";
        BBState.message = @"Open food delivery to continue";
    } else if ([phase isEqualToString:@"waitingForUser"] && hasCandidate && hasDraft) {
        BBState.phase = @"waiting_for_user";
        BBState.mailDraftPath = mailQueued ? nil : draftPath;
        BBState.appCandidatePath = appInstalled ? nil : candidatePath;
        BBState.message = mailQueued ?
            (installRequested ? @"Email queued; install the selected app" :
             @"Email queued; review the App Store listing") :
            (appInstalled ? @"Selected app is installed; review the email draft" :
             (installRequested ? @"Review PDF and email draft; install the selected app" :
              @"Review PDF, email draft and App Store listing"));
    } else if ([phase isEqualToString:@"waitingForUser"] && hasCandidate) {
        BBState.phase = @"waiting_for_user";
        BBState.message = installRequested ? @"Review the listing and install the selected app" :
            (hasPDF ? @"Review PDF and App Store listing" : @"Review the App Store listing");
        BBState.appCandidatePath = appInstalled ? nil : candidatePath;
    } else if ([phase isEqualToString:@"waitingForUser"] && hasPDF && hasDraft) {
        BBState.phase = @"waiting_for_user";
        BBState.message = @"Review the email draft";
        BBState.mailDraftPath = draftPath;
    } else if ([phase isEqualToString:@"completed"] && hasCandidate) {
        BBState.phase = @"done";
        BBState.message = mailQueued ? @"Research PDF available; email queued; selected app is installed" :
            (hasPDF ? @"Research PDF available; selected app is installed" :
             @"Selected app is installed");
    } else if ([phase isEqualToString:@"completed"] && hasPDF) {
        BBState.phase = @"done";
        BBState.message = @"Research PDF available";
    } else if ([phase isEqualToString:@"needsReconciliation"]) {
        BBState.phase = @"needs_reconciliation";
        BBState.message = @"Workflow outcome needs review";
    } else {
        BBState.phase = @"error";
        BBState.message = @"Interrupted workflow. Open Sessions to resume.";
    }
}

static void BBRestoreRecentWorkflow(void) {
    BBRestoreWorkflowIdentity(BBWorkflowSummaries().firstObject[@"id"]);
}

static NSString *BBNormalizeTask(NSString *task) {
    task = [task stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *lower = task.lowercaseString;
    if ([lower hasPrefix:@"please "])
        task = [[task substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *prefix in @[@"请帮我", @"帮我", @"请"]) {
        if ([task hasPrefix:prefix]) {
            task = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    NSCharacterSet *speechPunctuation = [NSCharacterSet characterSetWithCharactersInString:@"。.!！？?，,"];
    lower = task.lowercaseString;
    BOOL noteTask = [task hasPrefix:@"新建备忘录："] ||
        [lower hasPrefix:@"create note:"] || [lower hasPrefix:@"create a note:"];
    while (!noteTask && task.length &&
           [speechPunctuation characterIsMember:[task characterAtIndex:task.length - 1]])
        task = [[task substringToIndex:task.length - 1]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([task hasPrefix:@"打开一下"]) {
        NSString *name = [task substringFromIndex:@"打开一下".length];
        if ([@[@"设置", @"备忘录", @"地图", @"通讯录"] containsObject:name])
            task = [@"打开" stringByAppendingString:name];
    }
    for (NSString *prefix in @[@"在地图里搜索", @"在地图上搜索"]) {
        if ([task hasPrefix:prefix]) {
            task = [@"在地图搜索" stringByAppendingString:
                [task substringFromIndex:prefix.length]];
            break;
        }
    }
    lower = task.lowercaseString;
    NSDictionary *englishOpen = @{@"open settings": @"打开设置", @"open maps": @"打开地图",
        @"open contacts": @"打开通讯录", @"open notes": @"打开备忘录",
        @"open the settings": @"打开设置", @"open the maps": @"打开地图",
        @"open the contacts": @"打开通讯录", @"open the notes": @"打开备忘录"};
    if (englishOpen[lower]) return englishOpen[lower];
    for (NSString *prefix in @[@"search maps for ", @"find in maps "]) {
        if ([lower hasPrefix:prefix]) {
            NSString *place = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [@"在地图搜索" stringByAppendingString:place];
        }
    }
    for (NSString *prefix in @[@"create note:", @"create a note:"]) {
        if ([lower hasPrefix:prefix]) {
            NSString *content = [[task substringFromIndex:prefix.length]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return [@"新建备忘录：" stringByAppendingString:content];
        }
    }
    return task;
}

NSString *BBAllowedTarget(NSString *task) {
    if ([task isEqualToString:@"打开设置"]) return @"Settings";
    if ([task isEqualToString:@"打开备忘录"]) return @"Notes";
    if ([task isEqualToString:@"打开地图"]) return @"Maps";
    if ([task isEqualToString:@"打开通讯录"]) return @"Contacts";
    if ([task hasPrefix:@"在地图搜索"] && task.length > 5 && task.length <= 55 &&
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location == NSNotFound)
        return @"Maps";
    if (BBIsNoteTask(task)) return @"Notes";
    return nil;
}

static BOOL BBUsesTextHarness(NSString *task) {
    return [@[@"打开设置", @"打开备忘录", @"打开地图", @"打开通讯录"] containsObject:task];
}

static NSDictionary *BBStatus(void) {
    @synchronized (BBState) {
        NSMutableDictionary *status = [@{@"ok": @YES, @"phase": BBState.phase ?: @"idle",
                 @"message": BBState.message ?: @"",
                 @"app": BBState.app ?: @"", @"running": @(BBState.child > 0),
                 @"service_id": BBState.serviceID ?: @"",
                 @"task_id": BBState.taskID ?: @""} mutableCopy];
        if (BBState.reportPath) status[@"report_path"] = BBState.reportPath;
        if (BBState.mailDraftPath) status[@"mail_draft_path"] = BBState.mailDraftPath;
        if (BBState.appCandidatePath) status[@"app_candidate_path"] = BBState.appCandidatePath;
        if (BBState.deliveryAction) status[@"delivery_action"] = BBState.deliveryAction;
        return status;
    }
}

static NSString *BBFailureMessage(NSString *output) {
    if ([output containsString:@"Unsupported request"])
        return @"I could not identify one supported action. Try a clearer request.";
    if ([output containsString:@"Model settings changed"])
        return @"Model settings changed. Submit the task again.";
    if ([output containsString:@"Device is locked or screen is off"])
        return @"Unlock the phone and try again";
    if ([output containsString:@"Model key is not configured"])
        return @"Model key is missing or has unsafe permissions. Open Model settings.";
    if ([output containsString:@"Could not keep the screen awake"])
        return @"Could not keep the screen awake. Task stopped.";
    if ([output containsString:@"may contain sensitive information"] ||
        [output containsString:@"may contain a key"])
        return @"The screen or request may contain sensitive information. Task stopped.";
    if ([output containsString:@"Model request or response failed"])
        return @"Model request or response failed. Try again later.";
    if ([output containsString:@"Cannot safely use the current Maps screen"])
        return @"Cannot safely use the current Maps screen. Check it and try again.";
    if ([output containsString:@"Could not verify the requested place in Maps"])
        return @"Could not verify the requested place in Maps. Task stopped.";
    if ([output containsString:@"Model action was rejected by policy"])
        return @"The action failed the safety check. Task stopped.";
    if ([output containsString:@"Screen verification failed"])
        return @"The screen changed unexpectedly. Task stopped.";
    if ([output containsString:@"Notes screen is not safe to use"])
        return @"The Notes screen is not safe to use. Task stopped.";
    if ([output containsString:@"Task exceeded its time or step limit"])
        return @"Task exceeded its time or step limit";
    return @"Task incomplete. Check the screen and try again.";
}

static void BBWaitForChild(pid_t child, int readFD, NSUInteger generation,
                           NSString *completionMessage, NSString *app) {
    NSMutableData *output = [NSMutableData data];
    char buffer[512];
    for (;;) {
        ssize_t count = read(readFD, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        if (output.length < 2048) [output appendBytes:buffer length:MIN((NSUInteger)count, 2048 - output.length)];
    }
    close(readFD);
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    // SIGTERM does not execute the child's @finally. Release before another
    // task can start; the bridge lease also expires if this service dies.
    BBReleaseWakeLease();
    NSString *summary = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    summary = [summary stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *resolvedApp = nil;
    NSDictionary *deliveryAction = nil;
    for (NSString *line in [summary componentsSeparatedByString:@"\n"])
        if ([line hasPrefix:@"BB_DELIVERY_ACTION="]) {
            NSData *data = [[line substringFromIndex:@"BB_DELIVERY_ACTION=".length]
                dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *candidate = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *action = candidate[@"action"];
            NSString *target = candidate[@"target"];
            NSString *identity = candidate[@"observationID"];
            if ([@[@"open_search", @"search", @"open_merchant", @"open_item", @"review_options", @"choose_option",
                   @"add_to_cart", @"open_cart", @"review_cart", @"open_checkout", @"review_checkout"] containsObject:action] &&
                [target isKindOfClass:NSString.class] && target.length <= 120 &&
                [identity isKindOfClass:NSString.class] && identity.length == 64)
                deliveryAction = candidate;
        } else if ([line hasPrefix:@"BB_INTENT="]) {
            NSString *candidate = [line substringFromIndex:@"BB_INTENT=".length];
            if ([@[@"Settings", @"Maps", @"Contacts", @"Notes", @"MapsSearch", @"NoteCreate", @"ResearchPDF", @"ResearchMailDraft", @"ResearchAppStoreReview", @"AppStoreReview", @"DeliveryPlan"]
                    containsObject:candidate]) resolvedApp = candidate;
        }
    if (resolvedApp) {
        app = [resolvedApp isEqualToString:@"MapsSearch"] ? @"Maps" :
            ([resolvedApp isEqualToString:@"NoteCreate"] ? @"Notes" : resolvedApp);
        completionMessage = [resolvedApp isEqualToString:@"MapsSearch"] ? @"Maps search completed" :
            ([resolvedApp isEqualToString:@"NoteCreate"] ? @"Note created" :
             ([resolvedApp isEqualToString:@"ResearchPDF"] ? @"PDF report created" :
              ([resolvedApp isEqualToString:@"ResearchMailDraft"] ? @"Review the email draft" :
               ([resolvedApp isEqualToString:@"ResearchAppStoreReview"] ? @"Review PDF and App Store listing" :
               ([resolvedApp isEqualToString:@"AppStoreReview"] ? @"Review the App Store listing" :
                ([resolvedApp isEqualToString:@"DeliveryPlan"] ? @"Review next delivery step" : @"Target app is in the foreground"))))));
    }
    NSString *auditAction = nil, *auditResult = nil;
    @synchronized (BBState) {
        if (BBState.generation != generation || BBState.child != child) return;
        BOOL stopped = BBState.stopping;
        BBState.child = 0;
        BBState.app = app;
        BBState.stopping = NO;
        BOOL succeeded = waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
            (![resolvedApp isEqualToString:@"DeliveryPlan"] || deliveryAction != nil);
        BOOL uncertain = !stopped && !succeeded &&
            [BBWorkflowEffectivePhase(BBReadWorkflowRecord(BBState.taskID))
                isEqualToString:@"needsReconciliation"];
        BBState.phase = stopped ? @"stopped" :
            (succeeded ? (([resolvedApp isEqualToString:@"ResearchMailDraft"] ||
                           [resolvedApp isEqualToString:@"ResearchAppStoreReview"] ||
                           [resolvedApp isEqualToString:@"AppStoreReview"] ||
                           [resolvedApp isEqualToString:@"DeliveryPlan"]) ?
                          @"waiting_for_user" : @"done") :
             (uncertain ? @"needs_reconciliation" : @"error"));
        BBState.deliveryAction = succeeded && [resolvedApp isEqualToString:@"DeliveryPlan"] ?
            deliveryAction : nil;
        BOOL reportReady = succeeded &&
            ([@[@"ResearchPDF", @"ResearchMailDraft", @"ResearchAppStoreReview"] containsObject:resolvedApp]);
        BBState.reportPath = reportReady ?
            [NSString stringWithFormat:@"/var/mobile/Library/Application Support/BeanBao/workflows/%@/report.pdf",
                                       BBState.taskID ?: @""] : nil;
        NSString *draftPath = [NSString stringWithFormat:
            @"/var/mobile/Library/Application Support/BeanBao/workflows/%@/mail-draft.json",
            BBState.taskID ?: @""];
        BBState.mailDraftPath = succeeded &&
            ([@[@"ResearchMailDraft", @"ResearchAppStoreReview"] containsObject:resolvedApp]) &&
            BBPrivateWorkflowFile(draftPath, 1, 16 * 1024) ? draftPath : nil;
        BBState.appCandidatePath = succeeded &&
            ([@[@"AppStoreReview", @"ResearchAppStoreReview"] containsObject:resolvedApp]) ?
            [NSString stringWithFormat:@"/var/mobile/Library/Application Support/BeanBao/workflows/%@/app-candidate.json",
                                       BBState.taskID ?: @""] : nil;
        BBState.message = stopped ? @"Task stopped" :
            (succeeded ? (BBState.mailDraftPath && BBState.appCandidatePath ?
                          @"Review PDF, email draft and App Store listing" : completionMessage) :
             (uncertain ? @"Workflow outcome needs review" : BBFailureMessage(summary)));
        if (succeeded && [resolvedApp isEqualToString:@"ResearchAppStoreReview"] &&
            BBResearchAppInstallationCandidate(BBReadWorkflowRecord(BBState.taskID)[@"request"]))
            BBState.message = BBState.mailDraftPath ?
                @"Review PDF and email draft; install the selected app" :
                @"Review PDF and install the selected app";
        auditAction = BBState.phase;
        auditResult = succeeded ? @"ok" : @"failed";
    }
    BBAudit(@"task", app, auditAction, auditResult);
}

static NSDictionary *BBStart(NSDictionary *request) {
    NSString *task = request[@"task"];
    NSString *model = request[@"model"];
    NSString *resumeID = request[@"resume_id"];
    if (![task isKindOfClass:NSString.class] ||
        (model && ![model isKindOfClass:NSString.class]) ||
        (resumeID && ![resumeID isKindOfClass:NSString.class]) || task.length > 220)
        return @{@"ok": @NO, @"error": @"Invalid text request"};
    task = BBNormalizeTask(task);
    if (resumeID) {
        NSDictionary *saved = BBReadWorkflowRecord(resumeID);
        if (!saved || ![saved[@"request"] isEqualToString:task] ||
            ![@[@"planned", @"running", @"failed", @"cancelled"]
                containsObject:BBWorkflowEffectivePhase(saved)])
            return @{@"ok": @NO, @"error": @"This workflow cannot be resumed automatically"};
    }
    BOOL researchApp = BBResearchAppCandidate(task);
    BOOL researchPDF = !researchApp && BBIsResearchPDFTask(task);
    BOOL appStore = BBIsAppStoreTask(task);
    NSString *app = BBAllowedTarget(task);
    BOOL resolveTask = !app && !researchPDF && !researchApp && !appStore;
    if ((researchPDF || researchApp || appStore) && ![BBModelLoad()[@"provider"] isEqualToString:@"claude"])
        return @{@"ok": @NO, @"error": @"This workflow currently requires Claude"};
    if (resolveTask) app = @"BeanBao";
    if (researchPDF) app = @"ResearchPDF";
    if (researchApp) app = @"ResearchAppStoreReview";
    if (appStore) app = @"AppStoreReview";
    NSString *selectedProvider = BBModelLoad()[@"provider"];
    if (model && ![model isEqualToString:selectedProvider])
        return @{@"ok": @NO, @"error": @"Model settings changed. Submit the task again."};
    BOOL noteTask = BBIsNoteTask(task);
    NSString *completionMessage = BBCompletionMessage(task);
    @synchronized (BBState) {
        if (BBState.child > 0 || [BBState.phase isEqualToString:@"executing"])
            return @{@"ok": @NO, @"error": @"A task is already running"};
        int outputPipe[2];
        if (pipe(outputPipe)) return @{@"ok": @NO, @"error": @"Could not create the task pipe"};
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        char executable[PATH_MAX] = {0};
        uint32_t executableSize = sizeof(executable);
        if (_NSGetExecutablePath(executable, &executableSize)) {
            posix_spawn_file_actions_destroy(&actions); close(outputPipe[0]); close(outputPipe[1]);
            return @{@"ok": @NO, @"error": @"Could not locate the task executable"};
        }
        const char *argvMap[] = {executable, "--harness-map", task.UTF8String,
                                 selectedProvider.UTF8String, NULL};
        const char *argvNote[] = {executable, "--harness-note", task.UTF8String, NULL};
        const char *argvText[] = {executable, "--harness-text", task.UTF8String, NULL};
        NSString *taskID = resumeID ?: NSUUID.UUID.UUIDString;
        const char *argvResolve[] = {executable, "--resolve-task", task.UTF8String,
                                     selectedProvider.UTF8String, taskID.UTF8String, NULL};
        const char *argvResearch[] = {executable, "--workflow-research", task.UTF8String,
                                      taskID.UTF8String, NULL};
        const char *argvResearchApp[] = {executable, "--workflow-research-app", task.UTF8String,
                                         taskID.UTF8String, NULL};
        const char *argvAppStore[] = {executable, "--workflow-app-store", task.UTF8String,
                                      taskID.UTF8String, NULL};
        pid_t child = 0;
        int spawnResult = posix_spawn(&child, executable, &actions, NULL,
                                     (char *const *)(researchApp ? argvResearchApp :
                                         (researchPDF ? argvResearch :
                                         (appStore ? argvAppStore :
                                         (resolveTask ? argvResolve :
                                         (noteTask ? argvNote :
                                          (BBUsesTextHarness(task) ? argvText : argvMap)))))), environ);
        posix_spawn_file_actions_destroy(&actions);
        close(outputPipe[1]);
        if (spawnResult) { close(outputPipe[0]); return @{@"ok": @NO,
            @"error": [NSString stringWithFormat:@"Could not start the task process (%d)", spawnResult]}; }
        int readFD = outputPipe[0];
        BBState.generation++;
        NSUInteger generation = BBState.generation;
        BBState.taskID = taskID;
        BBState.reportPath = nil;
        BBState.mailDraftPath = nil;
        BBState.appCandidatePath = nil;
        BBState.deliveryAction = nil;
        BBState.child = child;
        BBState.stopping = NO;
        BBState.phase = @"running";
        BBState.message = @"Running";
        BBState.app = app;
        BBAudit(@"task", app, @"start", @"accepted");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBWaitForChild(child, readFD, generation, completionMessage, app);
        });
        return BBStatus();
    }
}

static NSDictionary *BBResumeWorkflow(NSDictionary *request) {
    NSString *identity = request[@"workflow_id"];
    NSDictionary *saved = BBReadWorkflowRecord(identity);
    if (!saved) return @{@"ok": @NO, @"error": @"Workflow not found"};
    return BBStart(@{@"task": saved[@"request"], @"resume_id": identity});
}

static NSDictionary *BBSelectWorkflow(NSDictionary *request) {
    NSString *identity = request[@"workflow_id"];
    if (!BBReadWorkflowRecord(identity))
        return @{@"ok": @NO, @"error": @"Workflow not found"};
    @synchronized (BBState) {
        if (BBState.child > 0 || [BBState.phase isEqualToString:@"executing"])
            return @{@"ok": @NO, @"error": @"A task is already running"};
        BBRestoreWorkflowIdentity(identity);
        return BBStatus();
    }
}

static NSDictionary *BBDeleteWorkflow(NSDictionary *request) {
    NSString *identity = request[@"workflow_id"];
    NSDictionary *record = BBReadWorkflowRecord(identity);
    if (!record)
        return @{@"ok": @NO, @"error": @"Workflow not found"};
    @synchronized (BBState) {
        if (BBState.child > 0 || [BBState.phase isEqualToString:@"executing"])
            return @{@"ok": @NO, @"error": @"A task is already running"};
        NSString *folder = BBWorkflowFolder(identity);
        NSSet<NSString *> *known = [NSSet setWithArray:
            @[@"session.json", @"report.json", @"report.pdf", @"mail-draft.json",
              @"app-search.json", @"app-candidate.json"]];
        NSArray<NSString *> *files = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:folder error:nil];
        if (!files || ![[NSSet setWithArray:files] isSubsetOfSet:known])
            return @{@"ok": @NO, @"error": @"Session contains files that need manual review"};
        for (NSString *name in files) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            if (!BBPrivateWorkflowFile(path, 0, 20 * 1024 * 1024))
                return @{@"ok": @NO, @"error": @"Session files are unsafe to delete"};
        }
        for (NSString *name in files) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            if (unlink(path.fileSystemRepresentation) && errno != ENOENT)
                return @{@"ok": @NO, @"error": @"Could not delete workflow files"};
        }
        if (rmdir(folder.fileSystemRepresentation))
            return @{@"ok": @NO, @"error": @"Could not delete workflow directory"};
        if ([BBState.taskID isEqualToString:identity]) {
            BBState.taskID = nil;
            BBState.app = nil;
            BBState.reportPath = nil;
            BBState.mailDraftPath = nil;
            BBState.appCandidatePath = nil;
            BBState.deliveryAction = nil;
            BBState.phase = @"idle";
            BBState.message = @"Waiting for a task";
        }
        BBAudit(@"workflow", BBIsDeliveryRecord(record) ?
            @"DeliveryPlan" : @"ResearchPDF", @"delete", @"ok");
        return @{@"ok": @YES};
    }
}

static NSDictionary *BBStop(NSDictionary *request) {
    @synchronized (BBState) {
        NSString *requestedTask = request[@"task_id"];
        NSString *requestedService = request[@"service_id"];
        if (requestedService && (![requestedService isKindOfClass:NSString.class] ||
                                 ![requestedService isEqualToString:BBState.serviceID ?: @""]))
            return @{@"ok": @NO, @"error": @"The service changed. No other task was stopped."};
        if (requestedTask && (![requestedTask isKindOfClass:NSString.class] ||
                              ![requestedTask isEqualToString:BBState.taskID ?: @""]))
            return @{@"ok": @NO, @"error": @"The task changed. No other task was stopped."};
        if (BBState.child <= 0 && [BBState.phase isEqualToString:@"executing"]) {
            BBState.phase = @"needs_reconciliation";
            BBState.message = @"The delivery step may have changed the cart. Check Uber Eats.";
            return BBStatus();
        }
        if (BBState.child <= 0) return BBStatus();
        BBState.stopping = YES;
        BBState.phase = @"stopping";
        BBState.message = @"Stopping";
        kill(BBState.child, SIGTERM);
        return BBStatus();
    }
}

static NSDictionary *BBMailResult(NSDictionary *request) {
    @synchronized (BBState) {
        NSString *taskID = request[@"task_id"];
        NSString *serviceID = request[@"service_id"];
        NSString *result = request[@"result"];
        if (![taskID isKindOfClass:NSString.class] ||
            ![serviceID isKindOfClass:NSString.class] ||
            ![taskID isEqualToString:BBState.taskID] ||
            ![serviceID isEqualToString:BBState.serviceID] ||
            !([@[@"ResearchMailDraft", @"ResearchAppStoreReview"] containsObject:BBState.app]) ||
            ![BBState.mailDraftPath isKindOfClass:NSString.class] ||
            ![BBState.phase isEqualToString:@"waiting_for_user"] ||
            ![@[@"sent", @"cancelled", @"failed"] containsObject:result])
            return @{@"ok": @NO, @"error": @"The email draft changed or the result is invalid"};
        if ([result isEqualToString:@"sent"]) {
            if (BBMarkResearchMailQueued(taskID.UTF8String) != 0) {
                BBState.phase = @"needs_reconciliation";
                BBState.message = @"Mail was queued, but its workflow record could not be saved. Check Apple Mail.";
                BBState.mailDraftPath = nil;
                BBAudit(@"task", @"ResearchMailDraft", @"needs_reconciliation", @"record_failed");
                return BBStatus();
            }
            BOOL appPending = [BBWorkflowEffectivePhase(BBReadWorkflowRecord(taskID))
                isEqualToString:@"waitingForUser"];
            BBState.phase = appPending ? @"waiting_for_user" : @"done";
            BBState.message = appPending ?
                (BBResearchAppInstallationCandidate(BBReadWorkflowRecord(taskID)[@"request"]) ?
                 @"Email queued in Mail; install the selected app" :
                 @"Email queued in Mail; review the App Store listing") :
                ([BBState.app isEqualToString:@"ResearchAppStoreReview"] ?
                 @"Email queued in Mail; selected app is installed" :
                 @"Email queued in Mail");
            BBState.mailDraftPath = nil;
            BBAudit(@"task", BBState.app, BBState.phase, @"queued");
        } else {
            BBState.message = [result isEqualToString:@"cancelled"] ?
                @"Email draft saved for review" : @"Mail could not queue the message";
            BBAudit(@"task", @"ResearchMailDraft", @"mail_review", result);
        }
        return BBStatus();
    }
}

static NSDictionary *BBVerifyAppInstall(NSDictionary *request) {
    @synchronized (BBState) {
        NSString *taskID = request[@"task_id"];
        NSString *serviceID = request[@"service_id"];
        if (![taskID isKindOfClass:NSString.class] ||
            ![serviceID isKindOfClass:NSString.class] ||
            ![taskID isEqualToString:BBState.taskID] ||
            ![serviceID isEqualToString:BBState.serviceID] ||
            ![BBState.phase isEqualToString:@"waiting_for_user"] ||
            !([@[@"AppStoreReview", @"ResearchAppStoreReview"] containsObject:BBState.app]))
            return @{@"ok": @NO, @"error": @"The App Store session changed"};
        NSDictionary *candidate = BBReadAppCandidate(taskID);
        NSString *bundle = candidate[@"bundleID"];
        if (!bundle) return @{@"ok": @NO, @"error": @"The saved App Store listing is unavailable"};
        if (!BBInstalledBundleVerified(bundle)) {
            BBState.message = @"App is not installed yet. Review the listing or check again.";
            NSMutableDictionary *status = [BBStatus() mutableCopy];
            status[@"installed"] = @NO;
            return status;
        }
        if (BBMarkAppStoreInstalled(taskID.UTF8String, bundle.UTF8String) != 0) {
            BBState.phase = @"needs_reconciliation";
            BBState.message = @"The app is installed, but its session could not be saved.";
            BBState.appCandidatePath = nil;
            BBAudit(@"task", @"AppStoreReview", @"needs_reconciliation", @"record_failed");
            return BBStatus();
        }
        BOOL mailPending = [BBWorkflowEffectivePhase(BBReadWorkflowRecord(taskID))
            isEqualToString:@"waitingForUser"];
        BBState.phase = mailPending ? @"waiting_for_user" : @"done";
        BBState.message = mailPending ? @"Selected app is installed; review the email draft" :
            ([BBState.app isEqualToString:@"ResearchAppStoreReview"] ?
             @"Research PDF available; selected app is installed" : @"Selected app is installed");
        BBState.appCandidatePath = nil;
        BBAudit(@"task", BBState.app, BBState.phase, @"installed");
        NSMutableDictionary *status = [BBStatus() mutableCopy];
        status[@"installed"] = @YES;
        return status;
    }
}

static NSDictionary *BBDeliveryObserve(NSDictionary *request) {
    NSDictionary *snapshot = request[@"snapshot"];
    if (![snapshot isKindOfClass:NSDictionary.class])
        return @{@"ok": @NO, @"error": @"Invalid delivery snapshot"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!data || data.length > 65536)
        return @{@"ok": @NO, @"error": @"Invalid delivery snapshot"};
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    char *receipt = json ? BBUberEatsClassifySnapshot(json.UTF8String) : NULL;
    if (!receipt) return @{@"ok": @NO, @"error": @"Delivery observation failed"};
    NSData *replyData = [NSData dataWithBytes:receipt length:strlen(receipt)];
    free(receipt);
    NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:replyData options:0 error:nil];
    return [reply isKindOfClass:NSDictionary.class] ? reply :
        @{@"ok": @NO, @"error": @"Delivery observation failed"};
}

static NSDictionary *BBDeliveryPlan(NSDictionary *request) {
    NSString *task = request[@"task"];
    NSString *resumeID = request[@"workflow_id"];
    NSDictionary *snapshot = request[@"snapshot"];
    if (![task isKindOfClass:NSString.class] || task.length < 2 || task.length > 220 ||
        [task rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
        ![snapshot isKindOfClass:NSDictionary.class] ||
        (resumeID && ![resumeID isKindOfClass:NSString.class]))
        return @{@"ok": @NO, @"error": @"Invalid delivery request"};
    NSDictionary *observed = BBDeliveryObserve(@{@"snapshot": snapshot});
    NSString *page = observed[@"page"];
    if (![observed[@"ok"] boolValue] ||
        ![@[@"feed", @"search_suggestions", @"search", @"merchant",
            @"item_configuration", @"cart_handoff", @"cart", @"checkout"] containsObject:page])
        return @{@"ok": @NO, @"error": @"Check a current Uber Eats page before planning"};
    NSData *snapshotData = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!snapshotData || snapshotData.length >= 65536)
        return @{@"ok": @NO, @"error": @"Delivery page is too large"};
    if (![BBModelLoad()[@"provider"] isEqualToString:@"claude"])
        return @{@"ok": @NO, @"error": @"Delivery planning currently requires Claude"};
    if (resumeID) {
        NSDictionary *saved = BBReadWorkflowRecord(resumeID);
        NSDictionary *operations = saved[@"operations"];
        BOOL hasDeliveryStep = NO;
        for (NSString *key in operations)
            if ([key hasPrefix:@"delivery-plan-v1-"]) { hasDeliveryStep = YES; break; }
        if (!saved || ![saved[@"request"] isEqualToString:task] || !hasDeliveryStep ||
            BBDeliveryHasUnfinishedAction(saved))
            return @{@"ok": @NO, @"error": @"Delivery session could not be resumed"};
    }
    @synchronized (BBState) {
        if (BBState.child > 0 || [BBState.phase isEqualToString:@"executing"] ||
            ([BBState.phase isEqualToString:@"needs_reconciliation"] &&
             [BBState.app isEqualToString:@"DeliveryPlan"]))
            return @{@"ok": @NO, @"error": @"A task is already running or needs review"};
        int inputPipe[2], outputPipe[2];
        if (pipe(inputPipe)) return @{@"ok": @NO, @"error": @"Could not create the task pipe"};
        if (pipe(outputPipe)) {
            close(inputPipe[0]); close(inputPipe[1]);
            return @{@"ok": @NO, @"error": @"Could not create the task pipe"};
        }
        posix_spawn_file_actions_t actions;
        posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_addclose(&actions, inputPipe[1]);
        posix_spawn_file_actions_addclose(&actions, outputPipe[0]);
        posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, inputPipe[0]);
        posix_spawn_file_actions_addclose(&actions, outputPipe[1]);
        char executable[PATH_MAX] = {0};
        uint32_t executableSize = sizeof(executable);
        if (_NSGetExecutablePath(executable, &executableSize)) {
            posix_spawn_file_actions_destroy(&actions);
            close(inputPipe[0]); close(inputPipe[1]);
            close(outputPipe[0]); close(outputPipe[1]);
            return @{@"ok": @NO, @"error": @"Could not locate the task executable"};
        }
        NSString *taskID = resumeID ?: NSUUID.UUID.UUIDString;
        const char *argv[] = {executable, "--workflow-delivery-plan", task.UTF8String,
                              taskID.UTF8String, NULL};
        pid_t child = 0;
        int spawned = posix_spawn(&child, executable, &actions, NULL, (char *const *)argv, environ);
        posix_spawn_file_actions_destroy(&actions);
        close(inputPipe[0]); close(outputPipe[1]);
        if (spawned) {
            close(inputPipe[1]); close(outputPipe[0]);
            return @{@"ok": @NO, @"error": @"Could not start delivery planning"};
        }
        const uint8_t *cursor = snapshotData.bytes;
        NSUInteger remaining = snapshotData.length;
        while (remaining) {
            ssize_t written = write(inputPipe[1], cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) break;
            cursor += written; remaining -= (NSUInteger)written;
        }
        close(inputPipe[1]);
        if (remaining) {
            kill(child, SIGTERM);
            close(outputPipe[0]);
            waitpid(child, NULL, 0);
            return @{@"ok": @NO, @"error": @"Could not send the delivery page"};
        }
        BBState.generation++;
        NSUInteger generation = BBState.generation;
        BBState.child = child;
        BBState.taskID = taskID;
        BBState.app = @"DeliveryPlan";
        BBState.phase = @"running";
        BBState.message = @"Planning next delivery step";
        BBState.stopping = NO;
        BBState.deliveryAction = nil;
        BBState.reportPath = nil;
        BBState.mailDraftPath = nil;
        BBState.appCandidatePath = nil;
        BBAudit(@"task", @"DeliveryPlan", @"start", @"accepted");
        int readFD = outputPipe[0];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            BBWaitForChild(child, readFD, generation, @"Review next delivery step", @"DeliveryPlan");
        });
        return BBStatus();
    }
}

static NSDictionary *BBDeliveryVerifyAction(NSDictionary *request) {
    NSString *taskID = request[@"task_id"];
    NSString *serviceID = request[@"service_id"];
    NSDictionary *snapshot = request[@"snapshot"];
    if (![taskID isKindOfClass:NSString.class] ||
        ![serviceID isKindOfClass:NSString.class] ||
        ![snapshot isKindOfClass:NSDictionary.class])
        return @{@"ok": @NO, @"error": @"Invalid delivery action check"};
    @synchronized (BBState) {
        if (![taskID isEqualToString:BBState.taskID] ||
            ![serviceID isEqualToString:BBState.serviceID] ||
            ![BBState.app isEqualToString:@"DeliveryPlan"] ||
            ![BBState.phase isEqualToString:@"waiting_for_user"] ||
            !BBState.deliveryAction)
            return @{@"ok": @NO, @"error": @"The delivery step changed"};
        NSData *snapshotData = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        NSData *actionData = [NSJSONSerialization dataWithJSONObject:BBState.deliveryAction
                                                              options:0 error:nil];
        if (!snapshotData || snapshotData.length >= 65536 ||
            !actionData || actionData.length >= 1024)
            return @{@"ok": @NO, @"error": @"Invalid delivery action check"};
        NSString *snapshotJSON = [[NSString alloc] initWithData:snapshotData encoding:NSUTF8StringEncoding];
        NSString *actionJSON = [[NSString alloc] initWithData:actionData encoding:NSUTF8StringEncoding];
        char *receipt = BBUberEatsValidateAction(snapshotJSON.UTF8String, actionJSON.UTF8String);
        if (!receipt) return @{@"ok": @NO, @"error": @"Delivery action check failed"};
        NSData *data = [NSData dataWithBytes:receipt length:strlen(receipt)];
        free(receipt);
        NSDictionary *result = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![result isKindOfClass:NSDictionary.class] || ![result[@"valid"] boolValue])
            return [result isKindOfClass:NSDictionary.class] ? result :
                @{@"ok": @NO, @"error": @"Delivery action check failed"};
        NSString *reviewAction = BBState.deliveryAction[@"action"];
        if ([reviewAction isEqualToString:@"review_options"] ||
            [reviewAction isEqualToString:@"review_cart"]) {
            if (BBDeliveryReadOnlyReviewFinish(taskID.UTF8String, actionJSON.UTF8String,
                                               snapshotJSON.UTF8String) != 0) {
                BBState.phase = @"error";
                BBState.message = @"Could not verify the delivery review. Check the page.";
                return @{@"ok": @NO, @"error": BBState.message};
            }
            BBState.phase = @"done";
            BBState.message = [reviewAction isEqualToString:@"review_cart"] ?
                @"Cart ready for review" : @"Item options ready for review";
            BBState.deliveryAction = nil;
            return result;
        }
        if ([BBState.deliveryAction[@"action"] isEqualToString:@"review_checkout"])
            return result;
        if (BBDeliveryActionBegin(taskID.UTF8String, actionJSON.UTF8String) != 0) {
            BBState.phase = @"needs_reconciliation";
            BBState.message = @"A delivery step may already have run. Check Uber Eats.";
            return @{@"ok": @NO, @"error": @"Delivery step outcome needs review"};
        }
        BBState.phase = @"executing";
        BBState.message = @"Checking delivery step result";
        return result;
    }
}

static NSDictionary *BBDeliveryActionAbortBeforeClick(NSDictionary *request) {
    NSString *taskID = request[@"task_id"];
    NSString *serviceID = request[@"service_id"];
    NSString *reason = request[@"reason"];
    NSSet *known = [NSSet setWithArray:@[@"Page changed", @"Sign-in page",
        @"Search control not unique", @"Search field not unique", @"Search form changed",
        @"Action target not unique", @"Option target not unique", @"Option changed",
        @"Link outside Uber Eats", @"Unsupported action"]];
    if (![taskID isKindOfClass:NSString.class] ||
        ![serviceID isKindOfClass:NSString.class] ||
        ![reason isKindOfClass:NSString.class] || ![known containsObject:reason])
        return @{@"ok": @NO, @"error": @"Invalid delivery abort"};
    @synchronized (BBState) {
        if (![taskID isEqualToString:BBState.taskID] ||
            ![serviceID isEqualToString:BBState.serviceID] ||
            ![BBState.app isEqualToString:@"DeliveryPlan"] ||
            ![BBState.phase isEqualToString:@"executing"] || !BBState.deliveryAction)
            return @{@"ok": @NO, @"error": @"The delivery step changed"};
        NSData *data = [NSJSONSerialization dataWithJSONObject:BBState.deliveryAction
                                                      options:0 error:nil];
        NSString *action = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!action || data.length >= 1024 ||
            BBDeliveryActionAbort(taskID.UTF8String, action.UTF8String) != 0)
            return @{@"ok": @NO, @"error": @"Could not close the unstarted step"};
        BBState.phase = @"stopped";
        BBState.message = @"Delivery step did not start";
        BBState.deliveryAction = nil;
        return BBStatus();
    }
}

static NSDictionary *BBDeliveryActionResult(NSDictionary *request) {
    NSString *taskID = request[@"task_id"];
    NSString *serviceID = request[@"service_id"];
    NSDictionary *snapshot = request[@"snapshot"];
    if (![taskID isKindOfClass:NSString.class] ||
        ![serviceID isKindOfClass:NSString.class] ||
        ![snapshot isKindOfClass:NSDictionary.class])
        return @{@"ok": @NO, @"error": @"Invalid delivery result"};
    @synchronized (BBState) {
        if (![taskID isEqualToString:BBState.taskID] ||
            ![serviceID isEqualToString:BBState.serviceID] ||
            ![BBState.app isEqualToString:@"DeliveryPlan"] ||
            ![@[@"executing", @"needs_reconciliation"] containsObject:BBState.phase] ||
            !BBState.deliveryAction)
            return @{@"ok": @NO, @"error": @"The delivery step changed"};
        NSData *snapshotData = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        NSData *actionData = [NSJSONSerialization dataWithJSONObject:BBState.deliveryAction
                                                              options:0 error:nil];
        if (!snapshotData || snapshotData.length >= 65536 ||
            !actionData || actionData.length >= 1024)
            return @{@"ok": @NO, @"error": @"Invalid delivery result"};
        NSString *snapshotJSON = [[NSString alloc] initWithData:snapshotData encoding:NSUTF8StringEncoding];
        NSString *actionJSON = [[NSString alloc] initWithData:actionData encoding:NSUTF8StringEncoding];
        if (BBDeliveryActionFinish(taskID.UTF8String, actionJSON.UTF8String,
                                   snapshotJSON.UTF8String) != 0) {
            BBState.phase = @"needs_reconciliation";
            BBState.message = @"The delivery step result needs review in Uber Eats.";
            return @{@"ok": @NO, @"error": @"Delivery step result could not be verified"};
        }
        BBState.phase = @"waiting_for_user";
        BBState.message = @"Delivery step verified";
        BBState.deliveryAction = nil;
        return BBStatus();
    }
}

static NSDictionary *BBHandle(NSDictionary *request) {
    NSString *op = request[@"op"];
    if ([op isEqualToString:@"status"]) return BBStatus();
    if ([op isEqualToString:@"pair_delivery"])
        return @{@"ok": @YES, @"token": BBBrowserPairingToken ?: @""};
    if ([op isEqualToString:@"start"]) return BBStart(request);
    if ([op isEqualToString:@"stop"]) return BBStop(request);
    if ([op isEqualToString:@"mail_result"]) return BBMailResult(request);
    if ([op isEqualToString:@"verify_app_install"]) return BBVerifyAppInstall(request);
    if ([op isEqualToString:@"delivery_observe"]) return BBDeliveryObserve(request);
    if ([op isEqualToString:@"delivery_plan"]) return BBDeliveryPlan(request);
    if ([op isEqualToString:@"delivery_verify_action"]) return BBDeliveryVerifyAction(request);
    if ([op isEqualToString:@"delivery_action_aborted"]) return BBDeliveryActionAbortBeforeClick(request);
    if ([op isEqualToString:@"delivery_action_result"]) return BBDeliveryActionResult(request);
    if ([op isEqualToString:@"list_workflows"])
        return @{@"ok": @YES, @"workflows": BBWorkflowSummaries()};
    if ([op isEqualToString:@"workflow_details"])
        return BBWorkflowDetails(request);
    if ([op isEqualToString:@"resume_workflow"]) return BBResumeWorkflow(request);
    if ([op isEqualToString:@"select_workflow"]) return BBSelectWorkflow(request);
    if ([op isEqualToString:@"delete_workflow"]) return BBDeleteWorkflow(request);
    return @{@"ok": @NO, @"error": @"Unknown operation"};
}

static int BBOpenBrowserListener(void) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = htons(BBBrowserPort);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || listen(listener, 4)) {
        close(listener);
        return -1;
    }
    return listener;
}

static BOOL BBPairingTokenMatches(NSString *candidate) {
    if (![candidate isKindOfClass:NSString.class] || candidate.length != 64 ||
        BBBrowserPairingToken.length != 64) return NO;
    const char *left = candidate.UTF8String;
    const char *right = BBBrowserPairingToken.UTF8String;
    uint8_t difference = 0;
    for (NSUInteger i = 0; i < 64; i++) difference |= (uint8_t)(left[i] ^ right[i]);
    return difference == 0;
}

static void BBClient(int fd, BOOL browserOnly) {
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    if (!browserOnly && (getpeereid(fd, &uid, &gid) || uid != 501)) return;
    struct timeval timeout = {.tv_sec = 3};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    NSMutableData *data = [NSMutableData data];
    BOOL complete = NO;
    uint8_t buffer[4096];
    while (data.length < 65536) {
        ssize_t count = read(fd, buffer, MIN(sizeof(buffer), 65536 - data.length));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) break;
        const uint8_t *end = memchr(buffer, '\n', (size_t)count);
        NSUInteger length = end ? (NSUInteger)(end - buffer) : (NSUInteger)count;
        [data appendBytes:buffer length:length];
        if (end) { complete = YES; break; }
    }
    NSDictionary *request = complete ?
        [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (data.length >= 4096 && ![@[@"delivery_observe", @"delivery_plan",
                                  @"delivery_verify_action", @"delivery_action_result"] containsObject:request[@"op"]])
        request = nil;
    BOOL allowed = !browserOnly || [@[@"status", @"stop", @"delivery_observe",
        @"delivery_plan", @"delivery_verify_action", @"delivery_action_aborted",
        @"delivery_action_result"]
        containsObject:request[@"op"]];
    if (browserOnly && [request[@"op"] isEqualToString:@"stop"]) {
        allowed = allowed && [request[@"task_id"] isKindOfClass:NSString.class] &&
            [request[@"service_id"] isKindOfClass:NSString.class] &&
            [BBState.app isEqualToString:@"DeliveryPlan"];
    }
    if (browserOnly) {
        allowed = allowed && BBPairingTokenMatches(request[@"delivery_token"]);
        NSMutableDictionary *sanitized = [request mutableCopy];
        [sanitized removeObjectForKey:@"delivery_token"];
        request = sanitized;
    }
    NSDictionary *reply = [request isKindOfClass:NSDictionary.class] && allowed ?
        BBHandle(request) : @{@"ok": @NO, @"error": @"Invalid request"};
    NSData *encoded = [NSJSONSerialization dataWithJSONObject:reply options:0 error:nil];
    if (encoded) {
        NSMutableData *line = [encoded mutableCopy];
        [line appendBytes:"\n" length:1];
        const uint8_t *cursor = line.bytes;
        NSUInteger remaining = line.length;
        while (remaining) {
            ssize_t written = write(fd, cursor, remaining);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) break;
            cursor += written; remaining -= (NSUInteger)written;
        }
    }
}

int BBServe(void) {
    @autoreleasepool {
        if (getuid() != 501) { fputs("beanbaod --serve must run as mobile\n", stderr); return 1; }
        BBState = [BBServiceState new];
        BBState.serviceID = NSUUID.UUID.UUIDString;
        BBState.phase = @"idle";
        BBState.message = @"Waiting for a task";
        uint8_t randomBytes[32];
        arc4random_buf(randomBytes, sizeof(randomBytes));
        NSMutableString *token = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i = 0; i < sizeof(randomBytes); i++)
            [token appendFormat:@"%02x", randomBytes[i]];
        BBBrowserPairingToken = token;
        BBRestoreRecentWorkflow();
        signal(SIGPIPE, SIG_IGN);
        umask(077);
        struct stat existing = {0};
        if (!lstat(BBServiceSocket, &existing)) {
            if (!S_ISSOCK(existing.st_mode) || existing.st_uid != 501 || unlink(BBServiceSocket)) return 1;
        } else if (errno != ENOENT) return 1;
        int listener = socket(AF_UNIX, SOCK_STREAM, 0);
        if (listener < 0) return 1;
        struct sockaddr_un address = {0};
        address.sun_family = AF_UNIX;
        strlcpy(address.sun_path, BBServiceSocket, sizeof(address.sun_path));
        if (bind(listener, (struct sockaddr *)&address, sizeof(address)) || chmod(BBServiceSocket, 0600) ||
            listen(listener, 4)) { close(listener); return 1; }
        int browserListener = BBOpenBrowserListener();
        for (;;) {
            @autoreleasepool {
                if (browserListener < 0)
                    browserListener = BBOpenBrowserListener();
                fd_set ready;
                FD_ZERO(&ready);
                FD_SET(listener, &ready);
                if (browserListener >= 0) FD_SET(browserListener, &ready);
                struct timeval waitTime = {.tv_sec = 1};
                int maximum = MAX(listener, browserListener);
                int count = select(maximum + 1, &ready, NULL, NULL, &waitTime);
                if (count < 0) { if (errno == EINTR) continue; break; }
                if (count && FD_ISSET(listener, &ready)) {
                    int client = accept(listener, NULL, NULL);
                    if (client >= 0) { BBClient(client, NO); close(client); }
                    else if (errno != EINTR) break;
                }
                if (browserListener >= 0 && count && FD_ISSET(browserListener, &ready)) {
                    int client = accept(browserListener, NULL, NULL);
                    if (client >= 0) { BBClient(client, YES); close(client); }
                    else if (errno != EINTR) { close(browserListener); browserListener = -1; }
                }
            }
        }
        if (browserListener >= 0) close(browserListener);
        close(listener);
        unlink(BBServiceSocket);
        return 1;
    }
}
