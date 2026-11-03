#import <Foundation/Foundation.h>
#import "../bridge/BBObservationClock.h"

// Exercise the exact on-device policy implementation without making bridge or model calls.
#define main beanbaod_entry
#include "../agent-native/beanbaod.m"
#undef main
#include "../agent-native/AgentService.m"

// The policy fixture includes the Objective-C entry point without linking the
// Swift harness; harness behavior has its own Swift package tests.
int32_t BBRunHarnessText(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessNote(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessMap(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessResearch(const char *task, const char *workflowID) {
    (void)task; (void)workflowID; return 1;
}
int32_t BBRunHarnessAppStore(const char *task, const char *workflowID) {
    (void)task; (void)workflowID; return 1;
}
int32_t BBRunHarnessDeliveryPlan(const char *task, const char *workflowID) {
    (void)task; (void)workflowID; return 1;
}
static int MailQueuedCalls = 0;
int32_t BBMarkResearchMailQueued(const char *workflowID) {
    (void)workflowID; MailQueuedCalls++; return 0;
}
int32_t BBMarkAppStoreInstalled(const char *workflowID, const char *bundleID) {
    (void)workflowID; (void)bundleID; return 0;
}
char *BBUberEatsClassifySnapshot(const char *snapshotJSON) {
    if (snapshotJSON && strstr(snapshotJSON, "View order"))
        return strdup("{\"ok\":true,\"page\":\"cart_handoff\",\"adapter_version\":3}");
    if (!snapshotJSON || !strstr(snapshotJSON, "Go to checkout")) return NULL;
    return strdup("{\"ok\":true,\"page\":\"cart\",\"adapter_version\":3}");
}
char *BBUberEatsValidateAction(const char *snapshotJSON, const char *actionJSON) {
    if (!snapshotJSON || !actionJSON) return NULL;
    return strdup("{\"ok\":true,\"valid\":true}");
}
static int DeliveryBeginCalls = 0;
static int DeliveryReviewCalls = 0;
int32_t BBDeliveryActionBegin(const char *workflowID, const char *actionJSON) {
    (void)workflowID; (void)actionJSON; DeliveryBeginCalls++; return 0;
}
int32_t BBDeliveryActionFinish(const char *workflowID, const char *actionJSON,
                               const char *snapshotJSON) {
    (void)workflowID; (void)actionJSON; (void)snapshotJSON; return 0;
}
int32_t BBDeliveryActionAbort(const char *workflowID, const char *actionJSON) {
    (void)workflowID; (void)actionJSON; return 0;
}
int32_t BBDeliveryReadOnlyReviewFinish(const char *workflowID, const char *actionJSON,
                                       const char *snapshotJSON) {
    (void)workflowID; (void)actionJSON; (void)snapshotJSON; DeliveryReviewCalls++; return 0;
}

static NSDictionary *Observation(NSString *app, BOOL locked, NSDictionary *ui, NSDictionary *ocr) {
    return @{@"device_state": @{@"locked_known": @YES, @"locked": @(locked),
                               @"screen_on_known": @YES, @"screen_on": @YES},
             @"frontmost_app": @{@"bundleId": app},
             @"screen": @{@"width": @414, @"height": @896},
             @"ui": ui ?: @{}, @"ocr": ocr ?: @{}};
}

static NSDictionary *StepObservation(NSDictionary *base, NSString *identifier) {
    NSMutableDictionary *result = [base mutableCopy];
    result[@"ok"] = @YES;
    result[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
    result[@"observation_id"] = identifier;
    return result;
}

static BOOL Check(BOOL condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL: %s\n", message);
    return condition;
}

int main(void) {
    @autoreleasepool {
        NSString *naturalResearch = @"Compare Apple Speech and Whisper, create a sourced PDF, and prepare an email to test@example.com";
        NSDictionary *researchChoice = @{ @"action": @"input_text", @"text": @"Research PDF" };
        if (!Check(BBResearchPDFCandidate(naturalResearch) &&
                   [BBResolvedTask(naturalResearch, researchChoice) isEqualToString:@"Research PDF"],
                   "model-classified research PDF and addressed mail enter one workflow") ||
            !Check(BBResearchPDFCandidate(@"Compare speech APIs, make a PDF, and send it to test@example.com") &&
                   [BBResolvedTask(@"Compare speech APIs, make a PDF, and send it to test@example.com",
                                   researchChoice) isEqualToString:@"Research PDF"],
                   "addressed email is allowed through the research draft handoff") ||
            !Check(!BBResearchPDFCandidate(@"Compare speech APIs, make a PDF, and email it") &&
                   BBResolvedTask(@"Compare speech APIs, make a PDF, and email it", researchChoice) == nil,
                   "email request without a recipient cannot silently complete as PDF only") ||
            !Check(!BBResearchPDFCandidate(@"Do not research speech APIs or create a PDF") &&
                   BBResolvedTask(@"Do not research speech APIs or create a PDF",
                                  researchChoice) == nil,
                   "a negated research request cannot start the PDF workflow") ||
            !Check(!BBIsResearchPDFTask(@"Research speech APIs, create a PDF, and install Pages") &&
                   !BBResearchPDFCandidate(@"Research speech APIs, create a PDF, and install Pages") &&
                   BBResolvedTask(@"Research speech APIs, create a PDF, and install Pages",
                                  researchChoice) == nil,
                   "research plus app installation cannot silently drop installation") ||
            !Check(!BBResearchPDFCandidate(@"Research speech APIs, create a PDF; install Pages") &&
                   !BBIsResearchPDFTask(@"Research speech APIs, create a PDF, install Pages"),
                   "punctuation cannot hide a second installation step") ||
            !Check(BBResearchAppCandidate(@"Research iOS speech, create a PDF, and find app Pages") &&
                   !BBResearchPDFCandidate(@"Research iOS speech, create a PDF, and find app Pages"),
                   "research plus app lookup enters the composite route, not PDF-only") ||
            !Check(!BBResearchAppCandidate(@"Research iOS speech, create a PDF, and find app Pages and Numbers") &&
                   !BBResearchAppCandidate(@"Research iOS speech, create a PDF, and find app Pages, then order lunch") &&
                   !BBResearchAppCandidate(@"Research iOS speech, create a PDF, and email it, then find app Pages") &&
                   !BBResearchAppCandidate(@"Research iOS speech, create a PDF, and send a message to test@example.com, then find app Pages"),
                   "composite route rejects multiple targets and unaddressed or unrelated actions") ||
            !Check(BBResearchAppCandidate(@"Research iOS speech, create a PDF, and prepare an email to test@example.com, then find app Pages") &&
                   BBResearchAppCandidate(@"Research iOS speech, create a PDF, and send it to test@example.com, then find app Pages"),
                   "addressed mail draft and app lookup share the research workflow") ||
            !Check([BBWorkflowKind(@"test", @{@"request":
                    @"Research iOS speech, create a PDF, and prepare an email to test@example.com, then find app Pages",
                    @"operations": @{@"mail": @{@"tool": @"mail_prepare", @"state": @"completed"}}})
                    isEqualToString:@"research_mail_app"],
                   "Sessions identifies a combined mail and app workflow") ||
            !Check(!BBResearchPDFCandidate(@"Compare speech APIs, make a PDF, and send a message to test@example.com") &&
                   BBResolvedTask(@"Compare speech APIs, make a PDF, and send a message to test@example.com",
                                  researchChoice) == nil,
                   "research cannot turn a message request into an email draft") ||
            !Check(!BBResearchPDFCandidate(@"Open Settings, compare speech APIs, and make a PDF") &&
                   BBResolvedTask(@"Open Settings, compare speech APIs, and make a PDF",
                                  researchChoice) == nil,
                   "research cannot drop a requested app switch")) return 1;
        if (!Check(BBObservationIsFresh(100, 109.9),
                   "recent monotonic observation remains valid") ||
            !Check(!BBObservationIsFresh(100, 110.1),
                   "expired monotonic observation is rejected") ||
            !Check(!BBObservationIsFresh(100, 99),
                   "clock rollback cannot revive an observation") ||
            !Check(!BBObservationIsFresh(NAN, 101),
                   "invalid observation time is rejected")) return 1;
        NSDictionary *uncertainOldRecord = @{@"phase": @"completed", @"operations": @{
            @"old-report": @{@"tool": @"report_compose", @"effect": @"localMutation",
                             @"state": @"needsReconciliation"}}};
        NSDictionary *interruptedRead = @{@"phase": @"running", @"operations": @{
            @"search": @{@"tool": @"web_search", @"effect": @"readOnly",
                           @"state": @"running"}}};
        if (!Check([BBWorkflowEffectivePhase(uncertainOldRecord)
                    isEqualToString:@"needsReconciliation"],
                   "an old completed record cannot hide an unresolved mutation") ||
            !Check([BBWorkflowEffectivePhase(interruptedRead) isEqualToString:@"running"],
                   "an interrupted read-only step remains resumable")) return 1;
        NSTimeInterval testNow = NSDate.date.timeIntervalSince1970;
        if (!Check(BBRecentObservation(@{@"timestamp": @(testNow - 1)}),
                   "recent Agent observation remains valid") ||
            !Check(!BBRecentObservation(@{@"timestamp": @(testNow + 60)}),
                   "future Agent observation is rejected") ||
            !Check(!BBRecentObservation(@{@"timestamp": @(testNow - 60)}),
                   "stale Agent observation is rejected")) return 1;
        BBState = [BBServiceState new];
        NSDictionary *delivery = BBHandle(@{@"op": @"delivery_observe",
            @"snapshot": @{@"url": @"https://www.ubereats.com/store/example/id",
                             @"visible_text": @"Go to checkout"}});
        if (!Check([delivery[@"page"] isEqualToString:@"cart"] &&
                   !delivery[@"visible_text"] &&
                   ![BBHandle(@{@"op": @"delivery_observe"})[@"ok"] boolValue],
                   "delivery observation returns only bounded page status")) return 1;
        NSDictionary *handoff = BBHandle(@{@"op": @"delivery_observe",
            @"snapshot": @{@"url": @"https://www.ubereats.com/store/example/id",
                            @"visible_text": @"View order Phin & Bowl 1"}});
        if (!Check([handoff[@"page"] isEqualToString:@"cart_handoff"],
                   "cart handoff is classified for the next planning step")) return 1;
        if (!Check(![BBHandle(@{@"op": @"delivery_plan", @"task": @"Find lunch"})[@"ok"] boolValue],
                   "delivery planning requires a current observed page")) return 1;
        if (!Check(![BBHandle(@{@"op": @"delivery_verify_action", @"task_id": @"old",
                               @"service_id": @"old", @"snapshot": @{}})[@"ok"] boolValue],
                   "delivery action requires the active planned step")) return 1;
        BBState.serviceID = @"service-A";
        BBState.taskID = @"task-A";
        BBState.phase = @"done";
        NSDictionary *identifiedStatus = BBStatus();
        if (!Check([identifiedStatus[@"service_id"] isEqualToString:@"service-A"] &&
                   [identifiedStatus[@"task_id"] isEqualToString:@"task-A"],
                   "status carries service and task identity") ||
            !Check(![BBStop(@{@"task_id": @"task-B"})[@"ok"] boolValue],
                   "stop refuses a different task identity") ||
            !Check(![BBStop(@{@"service_id": @"service-B"})[@"ok"] boolValue],
                   "stop refuses a different service identity")) return 1;
        BBState.app = @"DeliveryPlan";
        BBState.phase = @"waiting_for_user";
        BBState.deliveryAction = @{@"action": @"review_checkout", @"target": @"",
                                   @"observationID": @"1234567890123456789012345678901234567890123456789012345678901234"};
        NSDictionary *deliveryCheck = BBDeliveryVerifyAction(@{@"task_id": @"task-A",
            @"service_id": @"service-A", @"snapshot": @{@"visible_text": @"Place order"}});
        if (!Check([deliveryCheck[@"valid"] boolValue] && DeliveryBeginCalls == 0 &&
                   [BBState.phase isEqualToString:@"waiting_for_user"],
                   "checkout review never claims a browser mutation")) return 1;
        BBState.deliveryAction = @{@"action": @"review_options", @"target": @"",
                                   @"observationID": @"1234567890123456789012345678901234567890123456789012345678901234"};
        deliveryCheck = BBDeliveryVerifyAction(@{@"task_id": @"task-A",
            @"service_id": @"service-A", @"snapshot": @{@"visible_text": @"Add 1 to order"}});
        if (!Check([deliveryCheck[@"valid"] boolValue] && DeliveryReviewCalls == 1 &&
                   DeliveryBeginCalls == 0 && [BBState.phase isEqualToString:@"done"] &&
                   BBState.deliveryAction == nil,
                   "options review completes without claiming a cart mutation")) return 1;
        BBState.phase = @"waiting_for_user";
        BBState.deliveryAction = @{@"action": @"open_checkout", @"target": @"",
                                   @"observationID": @"1234567890123456789012345678901234567890123456789012345678901234"};
        deliveryCheck = BBDeliveryVerifyAction(@{@"task_id": @"task-A",
            @"service_id": @"service-A", @"snapshot": @{@"visible_text": @"Go to checkout"}});
        if (!Check([deliveryCheck[@"valid"] boolValue] && DeliveryBeginCalls == 1 &&
                   [BBState.phase isEqualToString:@"executing"],
                   "browser mutation is durably claimed before a click")) return 1;
        NSDictionary *deliveryResult = BBDeliveryActionResult(@{@"task_id": @"task-A",
            @"service_id": @"service-A", @"snapshot": @{@"visible_text": @"Place order"}});
        if (!Check([deliveryResult[@"phase"] isEqualToString:@"waiting_for_user"] &&
                   BBState.deliveryAction == nil,
                   "verified next page clears the pending browser action")) return 1;
        BBState.phase = @"executing";
        BBState.deliveryAction = @{@"action": @"choose_option", @"target": @"Rice Noodle",
            @"observationID": @"1234567890123456789012345678901234567890123456789012345678901234"};
        NSDictionary *aborted = BBDeliveryActionAbortBeforeClick(@{@"task_id": @"task-A",
            @"service_id": @"service-A", @"reason": @"Option changed"});
        if (!Check([aborted[@"phase"] isEqualToString:@"stopped"] &&
                   BBState.deliveryAction == nil,
                   "browser pre-click rejection closes the pending action")) return 1;
        BBState.phase = @"waiting_for_user";
        BBState.app = @"AppStoreReview";
        BBState.mailDraftPath = @"/tmp/test-draft.json";
        if (!Check(![BBMailResult(@{@"task_id": @"task-A", @"service_id": @"service-A",
                                    @"result": @"sent"})[@"ok"] boolValue] &&
                   MailQueuedCalls == 0 && [BBState.phase isEqualToString:@"waiting_for_user"],
                   "App Store workflow rejects a forged Mail result")) return 1;
        BBState.app = @"DeliveryPlan";
        if (!Check(![BBMailResult(@{@"task_id": @"task-A", @"service_id": @"service-A",
                                    @"result": @"cancelled"})[@"ok"] boolValue] &&
                   MailQueuedCalls == 0,
                   "delivery workflow rejects a forged Mail result")) return 1;
        BBState.app = @"ResearchMailDraft";
        BBState.mailDraftPath = nil;
        if (!Check(![BBMailResult(@{@"task_id": @"task-A", @"service_id": @"service-A",
                                    @"result": @"sent"})[@"ok"] boolValue] &&
                   MailQueuedCalls == 0,
                   "Mail result requires a prepared draft")) return 1;
        BBState.mailDraftPath = @"/tmp/test-draft.json";
        if (!Check(![BBMailResult(@{@"task_id": @"task-B", @"service_id": @"service-A",
                                   @"result": @"sent"})[@"ok"] boolValue],
                   "mail result rejects a stale task identity") ||
            !Check([BBMailResult(@{@"task_id": @"task-A", @"service_id": @"service-A",
                                  @"result": @"sent"})[@"phase"] isEqualToString:@"done"],
                   "mail sent callback changes waiting task to queued") ||
            !Check(MailQueuedCalls == 1,
                   "only the valid Mail result can queue a workflow") ||
            !Check(!BBState.mailDraftPath,
                   "queued mail no longer exposes the draft action") ||
            !Check(![BBMailResult(@{@"task_id": @"task-A", @"service_id": @"service-A",
                                   @"result": @"sent"})[@"ok"] boolValue],
                   "duplicate mail result is rejected")) return 1;
        NSString *workflowRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"BeanBao-workflow-policy-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSString *workflowID = NSUUID.UUID.UUIDString;
        NSString *workflowFolder = [workflowRoot stringByAppendingPathComponent:workflowID];
        BBWorkflowRoot = workflowRoot;
        if (![NSFileManager.defaultManager createDirectoryAtPath:workflowFolder
            withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:nil]) return 1;
        NSDictionary *savedWorkflow = @{@"id": workflowID, @"request": @"Research iOS speech and make a PDF",
                                        @"phase": @"completed", @"updatedAt": @1000};
        NSData *savedJSON = [NSJSONSerialization dataWithJSONObject:savedWorkflow options:0 error:nil];
        NSString *sessionPath = [workflowFolder stringByAppendingPathComponent:@"session.json"];
        [savedJSON writeToFile:sessionPath atomically:YES];
        chmod(sessionPath.fileSystemRepresentation, 0600);
        NSString *pdfPath = [workflowFolder stringByAppendingPathComponent:@"report.pdf"];
        [[NSMutableData dataWithLength:200] writeToFile:pdfPath atomically:YES];
        chmod(pdfPath.fileSystemRepresentation, 0600);
        if (!Check(BBWorkflowSummaries().count == 1,
                   "private saved workflow appears in Sessions") ||
            !Check([BBSelectWorkflow(@{@"workflow_id": workflowID})[@"phase"] isEqualToString:@"done"],
                   "selecting a saved workflow restores status") ||
            !Check([BBState.reportPath isEqualToString:pdfPath],
                   "selection exposes only a private regular PDF") ||
            !Check(![BBResumeWorkflow(@{@"workflow_id": workflowID})[@"ok"] boolValue],
                   "completed workflow cannot restart")) return 1;
        NSString *unknown = [workflowFolder stringByAppendingPathComponent:@"unexpected.txt"];
        [@"keep" writeToFile:unknown atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (!Check(![BBDeleteWorkflow(@{@"workflow_id": workflowID})[@"ok"] boolValue] &&
                   [NSFileManager.defaultManager fileExistsAtPath:sessionPath],
                   "unexpected file prevents partial session deletion")) return 1;
        unlink(unknown.fileSystemRepresentation);
        if (!Check([BBDeleteWorkflow(@{@"workflow_id": workflowID})[@"ok"] boolValue] &&
                   BBWorkflowSummaries().count == 0,
                   "session deletion removes known private files")) return 1;
        NSString *appID = NSUUID.UUID.UUIDString;
        NSString *appFolder = [workflowRoot stringByAppendingPathComponent:appID];
        [NSFileManager.defaultManager createDirectoryAtPath:appFolder withIntermediateDirectories:NO
                                  attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSDictionary *appRecord = @{@"id": appID, @"request": @"Install Example Notes",
                                     @"phase": @"waitingForUser", @"updatedAt": @1100};
        NSString *appSession = [appFolder stringByAppendingPathComponent:@"session.json"];
        [[NSJSONSerialization dataWithJSONObject:appRecord options:0 error:nil]
            writeToFile:appSession atomically:YES];
        chmod(appSession.fileSystemRepresentation, 0600);
        NSString *candidatePath = [appFolder stringByAppendingPathComponent:@"app-candidate.json"];
        NSDictionary *candidate = @{@"productID": @123456789, @"name": @"Example Notes",
                                     @"developer": @"Example Studio", @"bundleID": @"com.example.notinstalled",
                                     @"price": @0, @"currency": @"USD", @"country": @"US"};
        [[NSJSONSerialization dataWithJSONObject:candidate options:0 error:nil]
            writeToFile:candidatePath atomically:YES];
        chmod(candidatePath.fileSystemRepresentation, 0600);
        NSDictionary *appStatus = BBSelectWorkflow(@{@"workflow_id": appID});
        NSDictionary *notInstalled = BBVerifyAppInstall(@{@"task_id": appID,
            @"service_id": BBState.serviceID});
        if (!Check([appStatus[@"phase"] isEqualToString:@"waiting_for_user"] &&
                   [appStatus[@"app_candidate_path"] isEqualToString:candidatePath],
                   "saved App Store candidate opens for review") ||
            !Check([BBWorkflowSummaries().firstObject[@"kind"] isEqualToString:@"app_store"],
                   "Sessions identifies App Store handoff") ||
            !Check([notInstalled[@"ok"] boolValue] && ![notInstalled[@"installed"] boolValue] &&
                   [BBState.phase isEqualToString:@"waiting_for_user"],
                   "closing a listing cannot claim an uninstalled app succeeded") ||
            !Check([BBDeleteWorkflow(@{@"workflow_id": appID})[@"ok"] boolValue],
                   "App Store candidate and search files are user-deletable")) return 1;
        NSString *deliveryID = NSUUID.UUID.UUIDString;
        NSString *deliveryFolder = [workflowRoot stringByAppendingPathComponent:deliveryID];
        [NSFileManager.defaultManager createDirectoryAtPath:deliveryFolder withIntermediateDirectories:NO
                                  attributes:@{NSFilePosixPermissions: @0700} error:nil];
        NSDictionary *deliveryRecord = @{@"id": deliveryID, @"request": @"Find a rice bowl",
            @"phase": @"waitingForUser", @"updatedAt": @1200,
            @"operations": @{@"delivery-plan-v1-abc":
                @{@"tool": @"delivery_choose", @"state": @"completed", @"updatedAt": @1190,
                  @"result": @{@"action": @"search", @"target": @"rice bowl",
                               @"page_text": @"private website content"}}}};
        NSString *deliverySession = [deliveryFolder stringByAppendingPathComponent:@"session.json"];
        [[NSJSONSerialization dataWithJSONObject:deliveryRecord options:0 error:nil]
            writeToFile:deliverySession atomically:YES];
        chmod(deliverySession.fileSystemRepresentation, 0600);
        NSDictionary *deliveryStatus = BBSelectWorkflow(@{@"workflow_id": deliveryID});
        NSDictionary *deliveryDetails = BBWorkflowDetails(@{@"workflow_id": deliveryID});
        if (!Check([BBWorkflowSummaries().firstObject[@"kind"] isEqualToString:@"delivery"] &&
                   [deliveryStatus[@"app"] isEqualToString:@"DeliveryPlan"] &&
                   [deliveryStatus[@"phase"] isEqualToString:@"waiting_for_user"],
                   "delivery session is listed and restores as a delivery task") ||
            !Check([deliveryDetails[@"ok"] boolValue] &&
                   [deliveryDetails[@"steps"] count] == 1 &&
                   [deliveryDetails[@"steps"][0][@"tool"] isEqualToString:@"delivery_choose"] &&
                   [deliveryDetails[@"steps"][0][@"state"] isEqualToString:@"proposed"] &&
                   [deliveryDetails[@"steps"][0][@"title"] isEqualToString:@"Search for: rice bowl"] &&
                   ![deliveryDetails.description containsString:@"private website content"] &&
                   ![deliveryDetails.description containsString:@"delivery-plan-v1-abc"] &&
                   ![BBWorkflowDetails(@{@"workflow_id": NSUUID.UUID.UUIDString})[@"ok"] boolValue],
                   "workflow details expose bounded step status without tool results or receipt keys")) return 1;
        NSMutableDictionary *unfinished = [deliveryRecord mutableCopy];
        unfinished[@"operations"] = @{@"delivery-plan-v1-abc":
            @{@"tool": @"delivery_choose", @"state": @"completed", @"updatedAt": @1190,
              @"result": @{@"action": @"search", @"target": @"rice bowl"}},
            @"delivery-execute-v1-abc": @{@"tool": @"delivery_execute", @"state": @"running",
                @"updatedAt": @1200}};
        [[NSJSONSerialization dataWithJSONObject:unfinished options:0 error:nil]
            writeToFile:deliverySession atomically:YES];
        chmod(deliverySession.fileSystemRepresentation, 0600);
        NSDictionary *unfinishedDetails = BBWorkflowDetails(@{@"workflow_id": deliveryID});
        if (!Check([unfinishedDetails[@"steps"] count] == 1 &&
                   [unfinishedDetails[@"steps"][0][@"state"] isEqualToString:@"running"],
                   "delivery history merges a planned action and its execution receipt")) return 1;
        deliveryStatus = BBSelectWorkflow(@{@"workflow_id": deliveryID});
        if (!Check([deliveryStatus[@"phase"] isEqualToString:@"needs_reconciliation"],
                   "unfinished delivery action survives a service restart as uncertain") ||
            !Check([BBDeleteWorkflow(@{@"workflow_id": deliveryID})[@"ok"] boolValue],
                   "delivery session remains user-deletable after review")) return 1;
        rmdir(workflowRoot.fileSystemRepresentation);
        BBWorkflowRoot = @"/var/mobile/Library/Application Support/BeanBao/workflows";
        for (NSString *task in @[@"打开设置", @"打开备忘录", @"打开地图", @"打开通讯录"])
            if (!Check(BBUsesTextHarness(task), "fixed text opens use Palmino harness")) return 1;
        if (!Check(!BBUsesTextHarness(@"在地图搜索金门大桥") &&
                   !BBUsesTextHarness(@"新建备忘录：测试内容"),
                   "map search and note creation have separate bounded workflows")) return 1;
        if (!Check(BBIsResearchPDFTask(@"Research iOS speech recognition and create a PDF") &&
                   BBIsResearchPDFTask(@"调研设备语音识别并生成 PDF") &&
                   BBIsResearchPDFTask(@"Research iOS speech, create a PDF and email to test@example.com") &&
                   !BBIsResearchPDFTask(@"Research iOS speech and email the PDF to someone") &&
                   !BBIsResearchPDFTask(@"Open Maps"),
                   "research PDF routing requires an explicit address for email drafts")) return 1;
        if (!Check(BBIsAppStoreTask(@"Install Example Notes") &&
                   BBIsAppStoreTask(@"Download Example Notes") &&
                   !BBIsAppStoreTask(@"Install Example Notes and send an email") &&
                   !BBIsAppStoreTask(@"Open Maps"),
                   "App Store routing accepts a single explicit acquisition request")) return 1;
        if (!Check([BBResolvedTask(@"Find the Apple Mail app by Apple",
                                   @{@"action": @"input_text", @"text": @"Find app Apple Mail"})
                       isEqualToString:@"Find app Apple Mail"] &&
                   BBResolvedTask(@"Find the Apple Mail app by Apple",
                                  @{@"action": @"input_text", @"text": @"Find app Notes"}) == nil &&
                   BBResolvedTask(@"Find the Apple Mail app and send a message",
                                  @{@"action": @"input_text", @"text": @"Find app Apple Mail"}) == nil &&
                   BBResolvedTask(@"Find the Apple Mail app by Apple",
                                  @{@"action": @"done", @"text": @"Find app Apple Mail"}) == nil &&
                   BBResolvedTask(@"Find the Apple Mail app by Apple",
                                  @{@"action": @"input_text", @"text": @"Find app Apple Mail and pay"}) == nil,
                   "model-routed App Store lookup stays bound to one named app and one safe action")) return 1;
        char *invalidNoteJSON = BBNoteStepJSON("打开地图", "[]");
        NSDictionary *invalidNote = invalidNoteJSON ?
            [NSJSONSerialization JSONObjectWithData:
                [[NSString stringWithUTF8String:invalidNoteJSON] dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil] : nil;
        free(invalidNoteJSON);
        if (!Check([invalidNote[@"error"] isEqualToString:@"invalid_task"],
                   "note step rejects an unsupported task before Bridge access")) return 1;
        NSDictionary *invalidMap = BBMapStep(@"打开地图", @[], nil, nil, YES);
        if (!Check([invalidMap[@"error"] isEqualToString:@"invalid_task"],
                   "map step rejects an unsupported task before Bridge access")) return 1;
        NSDictionary *vision = @{ @"frontmost_app": @{ @"bundleId": @"com.apple.Maps" },
            @"screenshot": @{ @"data": @"YWJj" }, @"ui": @{ @"elements": @[] } };
        NSDictionary *openaiBody = BBOpenAIChatRequestBody(@"在地图搜索金门大桥", vision,
            @[], @"vision-test", NO);
        NSArray *openaiContent = openaiBody[@"messages"][1][@"content"];
        NSString *promptText = openaiContent[0][@"text"];
        if (!Check([openaiBody[@"model"] isEqualToString:@"vision-test"] &&
                   [openaiBody[@"max_completion_tokens"] integerValue] == 2048 &&
                   !openaiBody[@"max_tokens"], "OpenAI uses Chat Completions token field") ||
            !Check([openaiContent[1][@"image_url"][@"url"] isEqualToString:@"data:image/jpeg;base64,YWJj"] &&
                   ![promptText containsString:@"YWJj"],
                   "image bytes stay outside text prompt") ||
            !Check([BBOpenAIChatRequestBody(@"在地图搜索金门大桥", vision,
                @[], @"vision-test", YES)[@"max_tokens"] integerValue] == 2048,
                   "compatible API uses broad Chat Completions token field")) return 1;
        NSData *goodChat = [@"{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"{\\\"action\\\":\\\"done\\\"}\"}}]}"
            dataUsingEncoding:NSUTF8StringEncoding];
        NSData *truncatedChat = [@"{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"{\\\"action\\\":\\\"done\\\"}\"}}]}"
            dataUsingEncoding:NSUTF8StringEncoding];
        if (!Check([BBParseOpenAIChatAction(goodChat)[@"action"] isEqualToString:@"done"],
                   "Chat Completions action parses") ||
            !Check(BBParseOpenAIChatAction(truncatedChat)[@"error"] != nil,
                   "truncated model output cannot become an action")) return 1;
        NSString *invalidEndpoint = nil;
        if (!Check(!BBModelSave(@"compatible", @"vision-test", @"http://example.invalid/v1",
                                nil, &invalidEndpoint) && invalidEndpoint.length,
                   "compatible API rejects plaintext HTTP before writing")) return 1;
        NSDictionary *rejectedModel = BBStart(@{@"task": @"打开设置", @"model": @"mock"});
        NSDictionary *contactsIntent = @{@"action": @"input_text", @"text": @"打开通讯录"};
        if (!Check([BBNormalizeTask(@"  打开地图。 ") isEqualToString:@"打开地图"],
                   "speech punctuation normalization") ||
            !Check([BBResolvedTask(@"Open contacts open contacts", contactsIntent)
                    isEqualToString:@"打开通讯录"],
                   "model-resolved repeated app request remains one safe action") ||
            !Check(BBResolvedTask(@"Open Contacts and send a message", contactsIntent) == nil,
                   "model cannot discard an additional operation") ||
            !Check(BBResolvedTask(@"Open Settings and turn off Wi-Fi",
                                  @{@"action": @"input_text", @"text": @"打开设置"}) == nil,
                   "model cannot reduce a settings change to an app opening") ||
            !Check(BBResolvedTask(@"Do not open Contacts", contactsIntent) == nil,
                   "model cannot turn a negated request into an app launch") ||
            !Check(BBResolvedTask(@"Open Contacts", @{@"action": @"input_text",
                                                    @"text": @"打开短信"}) == nil,
                   "model cannot select a task outside the allowlist") ||
            !Check([BBResolvedTask(@"Find Golden Gate Bridge in Maps",
                                   @{@"action": @"input_text", @"text": @"在地图搜索Golden Gate Bridge"})
                    isEqualToString:@"在地图搜索Golden Gate Bridge"],
                   "model can identify a natural Maps search with exact place") ||
            !Check(BBResolvedTask(@"Find Golden Gate Bridge in Maps",
                                  @{@"action": @"input_text", @"text": @"在地图搜索Eiffel Tower"}) == nil,
                   "model cannot invent a Maps place") ||
            !Check([BBResolvedTask(@"Write a note saying Buy milk",
                                   @{@"action": @"input_text", @"text": @"新建备忘录：Buy milk"})
                    isEqualToString:@"新建备忘录：Buy milk"],
                   "model can identify a natural note request with exact content") ||
            !Check(BBResolvedTask(@"Write a note saying Buy milk",
                                  @{@"action": @"input_text", @"text": @"新建备忘录：Call Alice"}) == nil,
                   "model cannot invent note content") ||
            !Check([BBNormalizeTask(@"Please open Maps.") isEqualToString:@"打开地图"],
                   "English open command maps to the allowlist") ||
            !Check([BBNormalizeTask(@"Search Maps for Golden Gate Bridge.")
                    isEqualToString:@"在地图搜索Golden Gate Bridge"],
                   "English Maps search preserves the requested place") ||
            !Check([BBNormalizeTask(@"Create note: Buy milk.")
                    isEqualToString:@"新建备忘录：Buy milk."],
                   "English note creation preserves punctuation") ||
            !Check(BBAllowedTarget(BBNormalizeTask(@"Open Maps and send a message")) == nil,
                   "English compound request remains blocked") ||
            !Check([BBNormalizeTask(@"请帮我打开一下地图。") isEqualToString:@"打开地图"],
                   "polite fixed app open maps to the allowlist") ||
            !Check([BBNormalizeTask(@"帮我在地图里搜索金门大桥。") isEqualToString:@"在地图搜索金门大桥"],
                   "map search phrasing maps to the bounded task") ||
            !Check([BBNormalizeTask(@"请在地图上搜索加州科学院") isEqualToString:@"在地图搜索加州科学院"],
                   "second map search phrasing maps to the bounded task") ||
            !Check([BBNormalizeTask(@"请帮我新建备忘录：测试内容。") isEqualToString:@"新建备忘录：测试内容。"],
                   "polite note task preserves punctuation in content") ||
            !Check(BBAllowedTarget(BBNormalizeTask(@"请不要打开地图")) == nil,
                   "negated command is not converted to an open task") ||
            !Check(BBAllowedTarget(BBNormalizeTask(@"请帮我打开地图并发消息")) == nil,
                   "extra operation remains rejected after normalization") ||
            !Check(BBAuditRecord(@"task", @"地图", @"start", @"accepted").count == 5,
                   "audit record contains only fixed fields") ||
            !Check(BBAuditRecord(@"task", @"地图", @"tap 200,300", @"ok") == nil,
                   "audit rejects coordinates or free text") ||
            !Check([BBNormalizeTask(@"新建备忘录：测试内容。") isEqualToString:@"新建备忘录：测试内容。"],
                   "note text preserved") ||
            !Check([BBCompletionMessage(@"在地图搜索加州科学院") isEqualToString:@"Maps search completed"],
                   "map completion summary is fixed") ||
            !Check([BBCompletionMessage(@"新建备忘录：测试内容") isEqualToString:@"Note created"],
                   "note completion summary is fixed") ||
            !Check([BBFailureMessage(@"Model request or response failed: private model text")
                    isEqualToString:@"Model request or response failed. Try again later."],
                   "model error does not expose child output") ||
            !Check([BBFailureMessage(@"unexpected private output")
                    isEqualToString:@"Task incomplete. Check the screen and try again."],
                   "unknown error does not expose child output") ||
            !Check([BBFailureMessage(@"Notes screen is not safe to use")
                    isEqualToString:@"The Notes screen is not safe to use. Task stopped."],
                   "note state error is specific and fixed") ||
            !Check([BBFailureMessage(@"Could not keep the screen awake. Task stopped.")
                    isEqualToString:@"Could not keep the screen awake. Task stopped."],
                   "wake lease failure has a fixed message") ||
            !Check([BBFailureMessage(@"Could not verify the requested place in Maps")
                    isEqualToString:@"Could not verify the requested place in Maps. Task stopped."],
                   "unverified map input has a fixed message") ||
            !Check(BBFreshUICompatible(@"launch_app", NO, NO, NO, NO),
                   "allowlisted app launch tolerates source UI status changes") ||
            !Check(!BBFreshUICompatible(@"tap", NO, NO, NO, NO),
                   "coordinate action still requires matching source UI") ||
            !Check([BBAllowedTarget(@"新建备忘录：测试内容") isEqualToString:@"Notes"],
                   "note task accepted") ||
            !Check(![rejectedModel[@"ok"] boolValue],
                   "service rejects removed mock mode") ||
            !Check([BBAllowedTarget(@"打开通讯录") isEqualToString:@"Contacts"],
                   "Contacts opens only through the exact task") ||
            !Check([BBRequestedApp(@"打开通讯录") isEqualToString:@"com.apple.MobileAddressBook"],
                   "Contacts targets the installed bundle") ||
            !Check([BBAllowedTarget(@"打开通讯录") isEqualToString:@"Contacts"],
                   "Contacts remains an allowed fixed-open task") ||
            !Check(BBAllowedTarget(@"新建备忘录：短") == nil, "short note task refused") ||
            !Check(BBAllowedTarget(@"打开设置并删除账户") == nil, "unsafe extra instruction refused")) return 1;
        NSDictionary *mapUI = @{@"elements": @[@{@"text": @"搜索地图", @"visible_rect":
            @{@"x": @20, @"y": @200, @"width": @300, @"height": @50}}]};
        NSDictionary *map = Observation(@"com.apple.Maps", NO, mapUI, @{@"text": @"金门大桥"});
        NSString *mapTask = @"在地图搜索金门大桥";
        NSDictionary *sensitiveNotes = Observation(@"com.apple.mobilenotes", NO,
            @{@"elements": @[@{@"text": @"bearer token:abcdefghijkl"}]}, @{});
        NSDictionary *localMapLaunch = BBMapInitialLaunch(sensitiveNotes, @[]);
        if (!Check(BBHasSecret(sensitiveNotes[@"ui"]), "fixture contains a secret shape") ||
            !Check([localMapLaunch[@"action"] isEqualToString:@"launch_app"] &&
                   [localMapLaunch[@"bundle_id"] isEqualToString:@"com.apple.Maps"],
                   "map can leave a sensitive app with a fixed local launch") ||
            !Check(BBValidAction(localMapLaunch, sensitiveNotes, mapTask, @[], YES, YES, NO),
                   "fixed map launch remains within the map policy") ||
            !Check(!BBValidAction(localMapLaunch,
                Observation(@"com.apple.mobilenotes", YES, sensitiveNotes[@"ui"], @{}),
                mapTask, @[], YES, YES, NO), "fixed map launch remains blocked when locked") ||
            !Check(BBMapInitialLaunch(sensitiveNotes, @[@{@"action": @"launch_app"}]) == nil,
                   "map launch never repeats after an earlier step") ||
            !Check(BBMapInitialLaunch(map, @[]) == nil,
                   "map launch is unnecessary in Maps")) return 1;
        NSDictionary *tapSearch = @{@"action": @"tap", @"x": @100, @"y": @220};
        NSDictionary *closeOldCard = @{@"action": @"tap", @"x": @370, @"y": @530};
        NSDictionary *tapOther = @{@"action": @"tap", @"x": @350, @"y": @500};
        NSDictionary *inputPlace = @{@"action": @"input_text", @"text": @"金门大桥"};
        NSDictionary *enter = @{@"action": @"press_key", @"key": @"enter"};
        NSArray *mapOne = @[tapSearch], *mapTwo = @[tapSearch, inputPlace];
        NSArray *mapThree = @[tapSearch, inputPlace, enter];
        NSDictionary *focusedUI = @{@"elements": @[
            @{@"text": @"Search field", @"visible_rect":
              @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
            @{@"text": @"search", @"visible_rect":
              @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *focusedMap = Observation(@"com.apple.Maps", NO, focusedUI, @{});
        NSDictionary *oldQueryUI = @{@"elements": @[
            @{@"text": @"Search field", @"aliases": @[@"San Francisco City Hall"],
              @"visible_rect": @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
            @{@"text": @"Clear text", @"visible_rect":
              @{@"x": @308, @"y": @76, @"width": @20, @"height": @20}},
            @{@"text": @"search", @"visible_rect":
              @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *oldQueryMap = Observation(@"com.apple.Maps", NO, oldQueryUI, @{});
        NSDictionary *clearOldQuery = BBMapFixedClearTextAction(oldQueryMap, @"San Jose City Hall");
        NSString *sanJoseTask = @"在地图搜索San Jose City Hall";
        NSArray *priorSearchTaps = @[tapSearch, tapSearch];
        NSArray *clearedHistory = @[tapSearch, tapSearch, clearOldQuery];
        NSArray *typedAfterClear = @[tapSearch, tapSearch, clearOldQuery,
            @{@"action": @"input_text", @"text": @"San Jose City Hall"}];
        if (!Check([clearOldQuery[@"action"] isEqualToString:@"tap"] &&
                   BBValidAction(clearOldQuery, oldQueryMap, sanJoseTask,
                                 priorSearchTaps, YES, YES, NO),
                   "old Maps query is cleared through its exact control") ||
            !Check(!BBValidAction(@{@"action": @"input_text", @"text": @"San Jose City Hall"},
                                  oldQueryMap, sanJoseTask, priorSearchTaps, YES, YES, NO),
                   "new Maps query cannot append to uncleared text") ||
            !Check(BBMapFixedSelectionAction(oldQueryMap, @"San Jose City Hall",
                        @[@{@"action": @"input_text", @"text": @"San Jose City Hall"}]) == nil,
                   "stale field text after typing cannot trigger a second clear") ||
            !Check(BBValidAction(@{@"action": @"input_text", @"text": @"San Jose City Hall"},
                                 focusedMap, sanJoseTask, clearedHistory, YES, YES, NO),
                   "new Maps query is allowed after clearing old text") ||
            !Check(BBValidAction(@{@"action": @"press_key", @"key": @"enter"},
                                 Observation(@"com.apple.Maps", NO,
                                     @{@"elements": @[
                                         @{@"text": @"Search field", @"aliases": @[@"San Jose City Hall"],
                                           @"visible_rect": @{@"x": @16, @"y": @64,
                                                               @"width": @327, @"height": @44}},
                                         @{@"text": @"search", @"visible_rect":
                                           @{@"x": @309, @"y": @770,
                                             @"width": @100, @"height": @56}}]}, @{}),
                                 sanJoseTask, typedAfterClear, YES, YES, NO),
                   "Maps search can submit after a bounded clear-and-type sequence")) return 1;
        NSDictionary *searchedUI = @{@"elements": @[
            @{@"text": @"Search field", @"aliases": @[@"金门大桥"], @"visible_rect":
              @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
            @{@"text": @"search", @"visible_rect":
              @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *searchedMap = Observation(@"com.apple.Maps", NO, searchedUI, @{@"text": @"金门大桥"});
        NSDictionary *recentUI = @{@"elements": @[
            @{@"text": @"Search field", @"aliases": @[@"Apple Maps"], @"visible_rect":
              @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
            @{@"text": @"金门大桥", @"visible_rect":
              @{@"x": @20, @"y": @180, @"width": @300, @"height": @44}},
            @{@"text": @"search", @"visible_rect":
              @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *recentMap = Observation(@"com.apple.Maps", NO, recentUI, @{@"text": @"金门大桥"});
        if (!Check(!BBMapQueryInSearchField(recentMap, @"金门大桥") &&
                   [BBFixedMapAction(mapTask, recentMap, @[])[@"action"] isEqualToString:@"input_text"] &&
                   BBValidAction(inputPlace, recentMap, mapTask, @[], YES, YES, NO) &&
                   !BBValidAction(enter, recentMap, mapTask, @[], YES, YES, NO),
                   "Maps Recents cannot be mistaken for text in the search field")) return 1;
        NSDictionary *oldCard = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[@{@"text": @"Close", @"visible_rect":
                @{@"x": @350, @"y": @513, @"width": @42, @"height": @42}},
                @{@"text": @"Fisherman's Wharf", @"visible_rect":
                @{@"x": @119, @"y": @531, @"width": @174, @"height": @23}}]}, @{});
        NSDictionary *resultsUI = @{@"elements": @[
            @{@"text": @"Search field"}, @{@"text": @"金门大桥, Search Nearby"},
            @{@"text": @"Directions"}]};
        NSDictionary *resultsMap = Observation(@"com.apple.Maps", NO, resultsUI, @{});
        NSDictionary *placeCardUI = @{@"elements": @[
            @{@"text": @"Golden Gate Bridge", @"visible_rect":
              @{@"x": @215, @"y": @301, @"width": @30, @"height": @30}},
            @{@"text": @"Golden Gate Bridge, Landmark", @"visible_rect":
              @{@"x": @5, @"y": @498, @"width": @403, @"height": @59}}]};
        NSDictionary *placeCard = Observation(@"com.apple.Maps", NO, placeCardUI, @{});
        NSString *cityTask = @"在地图搜索San Francisco City Hall";
        NSDictionary *cityResultUI = @{@"elements": @[
            @{@"text": @"Search field", @"aliases": @[@"San Francisco City Hall"],
              @"visible_rect": @{@"x": @21, @"y": @514, @"width": @321, @"height": @43}},
            @{@"text": @"San Francisco City Hall, City Hall · 40 mi, 1 Dr Carlton B Goodlett Pl",
              @"visible_rect": @{@"x": @21, @"y": @495, @"width": @372, @"height": @133}}]};
        NSDictionary *cityResultOCR = @{@"texts": @[
            @{@"text": @"San Francisco City Hall", @"rect":
                @{@"x": @36, @"y": @645, @"width": @180, @"height": @18}}]};
        NSDictionary *cityResults = Observation(@"com.apple.Maps", NO,
                                                  cityResultUI, cityResultOCR);
        NSArray *cityHistory = @[@{@"action": @"launch_app", @"bundle_id": @"com.apple.Maps"},
            tapSearch, @{@"action": @"input_text", @"text": @"San Francisco City Hall"}, enter];
        NSDictionary *cityRowTap = BBMapFixedResultRowAction(cityResults, @"San Francisco City Hall");
        NSDictionary *wrongCityOCR = Observation(@"com.apple.Maps", NO, cityResultUI,
            @{@"texts": @[@{@"text": @"City of South San Francisco", @"rect":
                @{@"x": @36, @"y": @645, @"width": @180, @"height": @18}}]});
        if (!Check([cityRowTap[@"action"] isEqualToString:@"tap"] &&
                   BBValidAction(cityRowTap, cityResults, cityTask, cityHistory, YES, YES, NO),
                   "exact Maps result row can be selected using corroborated OCR") ||
            !Check(BBMapFixedResultRowAction(wrongCityOCR, @"San Francisco City Hall") == nil,
                   "different OCR result cannot authorize a Maps tap") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @180, @"y": @535},
                                  cityResults, cityTask, cityHistory, YES, YES, NO),
                   "shifted AX search-field coordinate cannot select a result row")) return 1;
        __block NSUInteger mapLaunchModelCalls = 0, mapLaunchActs = 0;
        __block BOOL mapLaunchScreenshotRequested = NO;
        BBNoteBridgeRequest mapLaunchBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                if ([request[@"screenshot"] boolValue]) mapLaunchScreenshotRequested = YES;
                return StepObservation(sensitiveNotes, @"map-launch");
            }
            if ([request[@"op"] isEqualToString:@"act"] &&
                [request[@"action"] isEqualToString:@"launch_app"] &&
                [request[@"bundle_id"] isEqualToString:@"com.apple.Maps"] &&
                [request[@"observation_id"] isEqualToString:@"map-launch"]) {
                mapLaunchActs++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        BBMapActionProvider unusedMapModel = ^NSDictionary *(__unused NSString *command,
                __unused NSDictionary *observation, __unused NSArray *history) {
            mapLaunchModelCalls++;
            return @{@"error": @"model must not see prior app"};
        };
        NSDictionary *mapLaunchStep = BBMapStep(mapTask, @[], mapLaunchBridge, unusedMapModel, YES);
        if (!Check([mapLaunchStep[@"ok"] boolValue] &&
                   [mapLaunchStep[@"action"][@"action"] isEqualToString:@"launch_app"] &&
                   mapLaunchActs == 1 && mapLaunchModelCalls == 0 &&
                   !mapLaunchScreenshotRequested,
                   "map harness leaves a sensitive app with a fixed local launch")) return 1;
        NSDictionary *switchedMapStep = BBMapStep(mapTask,
            @[@{@"action": @"launch_app", @"bundle_id": @"com.apple.Maps"}],
            mapLaunchBridge, unusedMapModel, YES);
        if (!Check([switchedMapStep[@"error"] isEqualToString:@"fresh_state"] &&
                   mapLaunchModelCalls == 0 && !mapLaunchScreenshotRequested,
                   "map harness stops after leaving Maps without capturing another app")) return 1;
        NSDictionary *sensitiveMap = Observation(@"com.apple.Maps", NO,
            sensitiveNotes[@"ui"], @{});
        __block BOOL sensitiveMapScreenshotRequested = NO;
        BBNoteBridgeRequest sensitiveMapBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                if ([request[@"screenshot"] boolValue]) sensitiveMapScreenshotRequested = YES;
                return StepObservation(sensitiveMap, @"map-sensitive");
            }
            return @{@"ok": @NO};
        };
        NSDictionary *sensitiveMapStep = BBMapStep(mapTask, @[], sensitiveMapBridge, unusedMapModel, YES);
        if (!Check([sensitiveMapStep[@"error"] isEqualToString:@"sensitive"] &&
                   mapLaunchModelCalls == 0 && !sensitiveMapScreenshotRequested,
                   "map harness never sends a sensitive Maps screen to the model")) return 1;
        __block NSUInteger visualReads = 0;
        BBNoteBridgeRequest changingMapBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                visualReads++;
                return StepObservation(visualReads == 1 ? map : sensitiveMap,
                    [NSString stringWithFormat:@"map-visual-%lu", (unsigned long)visualReads]);
            }
            return @{@"ok": @NO};
        };
        NSDictionary *changingMapStep = BBMapStep(mapTask, @[], changingMapBridge,
            unusedMapModel, YES);
        if (!Check([changingMapStep[@"error"] isEqualToString:@"sensitive"] &&
                   visualReads == 2 && mapLaunchModelCalls == 0,
                   "map harness rechecks the screenshot observation before a model call")) return 1;
        __block NSUInteger completedVisualReads = 0;
        BBNoteBridgeRequest completedVisualBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                completedVisualReads++;
                return StepObservation(completedVisualReads == 1 ? map : placeCard,
                    [NSString stringWithFormat:@"map-completed-%lu", (unsigned long)completedVisualReads]);
            }
            return @{@"ok": @NO};
        };
        NSDictionary *completedVisualStep = BBMapStep(mapTask, @[], completedVisualBridge,
            unusedMapModel, YES);
        if (!Check([completedVisualStep[@"ok"] boolValue] &&
                   [completedVisualStep[@"done"] boolValue] &&
                   completedVisualReads == 2 && mapLaunchModelCalls == 0,
                   "map harness finishes a result that appears before the model call")) return 1;
        __block NSUInteger rejectedMapActs = 0;
        BBNoteBridgeRequest mapBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"])
                return StepObservation(map, @"map-current");
            if ([request[@"op"] isEqualToString:@"act"]) rejectedMapActs++;
            return @{@"ok": @NO};
        };
        NSDictionary *rejectedMapStep = BBMapStep(mapTask, @[], mapBridge,
            ^NSDictionary *(__unused NSString *command, __unused NSDictionary *observation,
                             __unused NSArray *history) { return tapOther; }, YES);
        if (!Check([rejectedMapStep[@"error"] isEqualToString:@"policy"] &&
                   rejectedMapActs == 0,
                   "map harness blocks an unrelated model tap before Bridge action")) return 1;
        __block BOOL resultScreenshotRequested = NO;
        BBNoteBridgeRequest resultBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                if ([request[@"screenshot"] boolValue]) resultScreenshotRequested = YES;
                return StepObservation(placeCard, @"map-result");
            }
            return @{@"ok": @NO};
        };
        NSDictionary *verifiedMapStep = BBMapStep(mapTask, @[], resultBridge, unusedMapModel, YES);
        if (!Check([verifiedMapStep[@"ok"] boolValue] && [verifiedMapStep[@"done"] boolValue] &&
                   mapLaunchModelCalls == 0 && !resultScreenshotRequested,
                   "verified map pin and place card complete without screenshot or model")) return 1;
        __block BOOL localTapScreenshot = NO;
        __block NSUInteger localTapModelCalls = 0;
        BBNoteBridgeRequest localTapBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                if ([request[@"screenshot"] boolValue]) localTapScreenshot = YES;
                return StepObservation(map, @"map-after-launch");
            }
            if ([request[@"op"] isEqualToString:@"act"] &&
                [request[@"action"] isEqualToString:@"tap"]) return @{@"ok": @YES};
            return @{@"ok": @NO};
        };
        NSDictionary *localTapAfterLaunch = BBMapStep(mapTask,
            @[@{@"action": @"launch_app", @"bundle_id": @"com.apple.Maps"}],
            localTapBridge,
            ^NSDictionary *(__unused NSString *command, __unused NSDictionary *observation,
                             __unused NSArray *history) {
                localTapModelCalls++;
                return BBError(@"unexpected model call");
            }, YES);
        if (!Check([localTapAfterLaunch[@"ok"] boolValue] &&
                   [localTapAfterLaunch[@"action"][@"action"] isEqualToString:@"tap"] &&
                   localTapScreenshot && localTapModelCalls == 0,
                   "verified search tap after Maps launch avoids an unnecessary model action")) return 1;
        NSArray *mapJourneyStates = @[map, focusedMap, searchedMap, placeCard];
        NSArray *mapJourneyActions = @[tapSearch, inputPlace, enter];
        __block NSUInteger mapJourneyStage = 0, mapJourneyReads = 0, mapJourneyModelCalls = 0;
        __block BOOL mapJourneyScreenshotRequested = NO;
        BBNoteBridgeRequest mapJourneyBridge = ^NSDictionary *(NSDictionary *request) {
            NSString *op = request[@"op"];
            if ([op isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([op isEqualToString:@"observe"]) {
                if ([request[@"screenshot"] boolValue]) mapJourneyScreenshotRequested = YES;
                return StepObservation(mapJourneyStates[MIN(mapJourneyStage, 3)],
                    [NSString stringWithFormat:@"map-journey-%lu", (unsigned long)++mapJourneyReads]);
            }
            if ([op isEqualToString:@"act"] && mapJourneyStage < 3 &&
                [request[@"action"] isEqualToString:mapJourneyActions[mapJourneyStage][@"action"]] &&
                [request[@"observation_id"] isEqualToString:
                    [NSString stringWithFormat:@"map-journey-%lu", (unsigned long)mapJourneyReads]]) {
                mapJourneyStage++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        BBMapActionProvider mapJourneyModel = ^NSDictionary *(__unused NSString *command,
                __unused NSDictionary *observation, NSArray *history) {
            mapJourneyModelCalls++;
            return history.count < 3 ? mapJourneyActions[history.count] : @{@"action": @"done"};
        };
        NSMutableArray *mapJourneyHistory = [NSMutableArray array];
        NSDictionary *mapJourneyResult = nil;
        for (NSUInteger step = 0; step < 4; step++) {
            mapJourneyResult = BBMapStep(mapTask, mapJourneyHistory, mapJourneyBridge, mapJourneyModel, YES);
            if (![mapJourneyResult[@"ok"] boolValue] || [mapJourneyResult[@"done"] boolValue]) break;
            [mapJourneyHistory addObject:mapJourneyResult[@"action"]];
        }
        if (!Check([mapJourneyResult[@"ok"] boolValue] && [mapJourneyResult[@"done"] boolValue] &&
                   mapJourneyStage == 3 && mapJourneyHistory.count == 3 &&
                   mapJourneyModelCalls == 1 && mapJourneyScreenshotRequested,
                   "map harness uses local exact text and enter after model opens search")) return 1;
        NSDictionary *localClose = BBFixedMapAction(mapTask, oldCard, @[]);
        if (!Check([localClose[@"action"] isEqualToString:@"tap"] &&
                   BBValidAction(localClose, oldCard, mapTask, @[], YES, YES, NO),
                   "local planner closes an old map place card within policy")) return 1;
        NSDictionary *unsupportedMap = BBFixedMapAction(mapTask,
            Observation(@"com.apple.Maps", NO, @{}, @{}), @[]);
        if (!Check([unsupportedMap[@"error"] isEqualToString:@"local_state"],
                   "local planner stops when Maps controls are not recognized")) return 1;
        mapJourneyStage = 0;
        mapJourneyReads = 0;
        mapJourneyScreenshotRequested = NO;
        NSMutableArray *localMapHistory = [NSMutableArray array];
        NSDictionary *localMapResult = nil;
        BBMapActionProvider localMapModel = ^NSDictionary *(NSString *command,
                NSDictionary *observation, NSArray *history) {
            return BBFixedMapAction(command, observation, history);
        };
        for (NSUInteger step = 0; step < 4; step++) {
            localMapResult = BBMapStep(mapTask, localMapHistory, mapJourneyBridge, localMapModel, NO);
            if (![localMapResult[@"ok"] boolValue] || [localMapResult[@"done"] boolValue]) break;
            [localMapHistory addObject:localMapResult[@"action"]];
        }
        if (!Check([localMapResult[@"ok"] boolValue] && [localMapResult[@"done"] boolValue] &&
                   mapJourneyStage == 3 && localMapHistory.count == 3 &&
                   !mapJourneyScreenshotRequested,
                   "mock map planner completes the search without a screenshot or remote model")) return 1;
        NSDictionary *transitionMap = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[]}, @{});
        __block NSUInteger delayedFocusReads = 0, delayedFocusActs = 0;
        BBNoteBridgeRequest delayedFocusBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                delayedFocusReads++;
                return StepObservation(delayedFocusReads == 1 ? transitionMap : focusedMap,
                    [NSString stringWithFormat:@"delayed-focus-%lu", (unsigned long)delayedFocusReads]);
            }
            if ([request[@"op"] isEqualToString:@"act"] &&
                [request[@"action"] isEqualToString:@"input_text"] &&
                [request[@"text"] isEqualToString:@"金门大桥"]) {
                delayedFocusActs++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        NSDictionary *delayedFocusStep = BBMapStep(mapTask, @[tapSearch],
            delayedFocusBridge, localMapModel, NO);
        if (!Check([delayedFocusStep[@"ok"] boolValue] &&
                   [delayedFocusStep[@"action"][@"action"] isEqualToString:@"input_text"] &&
                   delayedFocusReads >= 3 && delayedFocusActs == 1,
                   "mock map planner waits for the search field after opening it")) return 1;
        NSDictionary *fishermanCard = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"Fisherman's Wharf", @"visible_rect":
                  @{@"x": @155, @"y": @298, @"width": @30, @"height": @30}},
                @{@"text": @"Fisherman's Wharf, Attraction", @"visible_rect":
                  @{@"x": @5, @"y": @498, @"width": @403, @"height": @59}}]}, @{});
        NSDictionary *staleCard = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"CA-1 S", @"visible_rect":
                  @{@"x": @223, @"y": @286, @"width": @30, @"height": @30}},
                @{@"text": @"CA-1 S", @"visible_rect":
                  @{@"x": @5, @"y": @498, @"width": @403, @"height": @59}},
                @{@"text": @"Directions"}, @{@"text": @"Searching…"}]},
            @{@"text": @"加州科学院"});
        NSDictionary *academySuggestion = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"Search field", @"aliases": @[@"加州科学院"], @"visible_rect":
                  @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
                @{@"text": @"search", @"visible_rect":
                  @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}},
                @{@"text": @"California Academy of Sciences, 41 mi · 55 Music Concourse Dr", @"visible_rect":
                  @{@"x": @76, @"y": @62, @"width": @300, @"height": @62}}]},
            @{@"texts": @[@{@"text": @"California Academy of Sciences", @"rect":
                @{@"x": @76, @"y": @141, @"width": @241, @"height": @18}}]});
        NSDictionary *academyTap = @{@"action": @"tap", @"x": @196, @"y": @150};
        NSDictionary *academyRowTap = @{@"action": @"tap", @"x": @300, @"y": @185};
        NSDictionary *academyInput = @{@"action": @"input_text", @"text": @"加州科学院"};
        __block NSUInteger delayedMapReads = 0, delayedMapActs = 0;
        BBNoteBridgeRequest delayedMapBridge = ^NSDictionary *(NSDictionary *request) {
            NSString *op = request[@"op"];
            if ([op isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([op isEqualToString:@"observe"]) {
                delayedMapReads++;
                return StepObservation(delayedMapReads == 1 ? focusedMap : academySuggestion,
                    [NSString stringWithFormat:@"delayed-map-%lu", (unsigned long)delayedMapReads]);
            }
            if ([op isEqualToString:@"act"] && [request[@"action"] isEqualToString:@"tap"] &&
                [request[@"observation_id"] isEqualToString:
                    [NSString stringWithFormat:@"delayed-map-%lu", (unsigned long)delayedMapReads]]) {
                delayedMapActs++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        NSDictionary *delayedMapStep = BBMapStep(@"在地图搜索加州科学院",
            @[tapSearch, academyInput], delayedMapBridge, unusedMapModel, NO);
        if (!Check([delayedMapStep[@"ok"] boolValue] &&
                   [delayedMapStep[@"action"][@"action"] isEqualToString:@"tap"] &&
                   delayedMapActs == 1 && mapLaunchModelCalls == 0,
                   "map harness waits for typed text and then taps a verified suggestion")) return 1;
        __block NSUInteger missingTextActs = 0;
        BBNoteBridgeRequest missingTextBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"])
                return StepObservation(focusedMap, @"missing-text");
            if ([request[@"op"] isEqualToString:@"act"]) missingTextActs++;
            return @{@"ok": @NO};
        };
        NSDictionary *missingTextStep = BBMapStep(@"在地图搜索加州科学院",
            @[tapSearch, academyInput], missingTextBridge, unusedMapModel, NO);
        if (!Check([missingTextStep[@"error"] isEqualToString:@"input_unverified"] &&
                   missingTextActs == 0 && mapLaunchModelCalls == 0,
                   "map harness stops when entered text never becomes visible")) return 1;
        NSDictionary *afterSuggestion = BBFixedMapAction(@"在地图搜索加州科学院",
            academySuggestion, @[tapSearch, academyInput, academyTap]);
        if (!Check([afterSuggestion[@"action"] isEqualToString:@"done"] &&
                   !BBValidAction(afterSuggestion, academySuggestion,
                       @"在地图搜索加州科学院", @[tapSearch, academyInput, academyTap], YES, YES, NO),
                   "local planner waits for a verified result after tapping a suggestion")) return 1;
        NSDictionary *islandSuggestion = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"Search field", @"aliases": @[@"Alcatraz Island"], @"visible_rect":
                  @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
                @{@"text": @"search", @"visible_rect":
                  @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}},
                @{@"text": @"Search results", @"visible_rect":
                  @{@"x": @0, @"y": @0, @"width": @414, @"height": @820}},
                @{@"text": @"Alcatraz Island, 43 mi · CA, United States", @"visible_rect":
                  @{@"x": @16, @"y": @144, @"width": @382, @"height": @68}},
                @{@"text": @"Alcatraz Island, Search Nearby", @"visible_rect":
                  @{@"x": @16, @"y": @282, @"width": @382, @"height": @68}},
                @{@"text": @"Alcatraz Island, 43 mi · San Francisco, CA, United States", @"visible_rect":
                  @{@"x": @16, @"y": @420, @"width": @382, @"height": @68}}]},
            @{@"texts": @[
                @{@"text": @"Alcatraz Island", @"rect": @{@"x": @76, @"y": @237, @"width": @118, @"height": @15}},
                @{@"text": @"Alcatraz Island", @"rect": @{@"x": @76, @"y": @375, @"width": @118, @"height": @15}},
                @{@"text": @"Search Nearby", @"rect": @{@"x": @76, @"y": @399, @"width": @130, @"height": @15}},
                @{@"text": @"Alcatraz Island", @"rect": @{@"x": @76, @"y": @513, @"width": @118, @"height": @15}}]});
        NSDictionary *towerSuggestion = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"Search field", @"aliases": @[@"Coit Tower"], @"visible_rect":
                  @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
                @{@"text": @"search", @"visible_rect":
                  @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}},
                @{@"text": @"Coit Tower, 41 mi · 1 Telegraph Hill Blvd", @"visible_rect":
                  @{@"x": @76, @"y": @62, @"width": @291, @"height": @62}}]},
            @{@"texts": @[@{@"text": @"Coit Tower", @"rect":
                @{@"x": @75, @"y": @138, @"width": @88, @"height": @19}}]});
        NSDictionary *pierSuggestion = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"Search field", @"aliases": @[@"PIER 39"], @"visible_rect":
                  @{@"x": @16, @"y": @64, @"width": @327, @"height": @44}},
                @{@"text": @"search", @"visible_rect":
                  @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}},
                @{@"text": @"Pier 39, 41 mi · San Francisco", @"visible_rect":
                  @{@"x": @16, @"y": @144, @"width": @382, @"height": @68}}]},
            @{@"texts": @[@{@"text": @"Pier 39", @"rect":
                @{@"x": @75, @"y": @234, @"width": @59, @"height": @17}}]});
        NSDictionary *academyCard = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[
                @{@"text": @"California Academy of Sciences", @"visible_rect":
                  @{@"x": @188, @"y": @298, @"width": @30, @"height": @30}},
                @{@"text": @"California Academy of Sciences, Science Museum", @"visible_rect":
                  @{@"x": @5, @"y": @498, @"width": @403, @"height": @59}}]}, @{});
        NSDictionary *tower3DCard = Observation(@"com.apple.Maps", NO,
            @{@"elements": @[@{@"text": @"Coit Tower, Observation Deck", @"visible_rect":
                @{@"x": @5, @"y": @498, @"width": @403, @"height": @59}}]},
            @{@"texts": @[@{@"text": @"COIT TOWER", @"rect":
                @{@"x": @171, @"y": @169, @"width": @76, @"height": @12}}]});
        NSArray *mapDirectOne = @[inputPlace], *mapDirectTwo = @[inputPlace, enter];
        NSArray *mapAfterClose = @[closeOldCard], *mapAfterTwoTaps = @[closeOldCard, tapSearch];
        NSArray *mapAfterTwoTapsInput = @[closeOldCard, tapSearch, inputPlace];
        NSArray *mapAfterTwoTapsSubmit = @[closeOldCard, tapSearch, inputPlace, enter];
        if (!Check(BBValidAction(tapSearch, map, mapTask, @[], YES, YES, NO), "map search tap allowed") ||
            !Check(BBValidAction(closeOldCard, oldCard, mapTask, @[], YES, YES, NO),
                   "old map card close allowed") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @370, @"y": @80},
                                  Observation(@"com.apple.Maps", NO,
                                    @{@"elements": @[@{@"text": @"Close", @"visible_rect":
                                      @{@"x": @350, @"y": @64, @"width": @42, @"height": @42}}]}, @{}),
                                  mapTask, @[], YES, YES, NO), "top close blocked") ||
            !Check(BBValidAction(tapSearch, map, mapTask, mapAfterClose, YES, YES, NO),
                   "search tap after old card close allowed") ||
            !Check(BBValidAction(inputPlace, focusedMap, mapTask, mapAfterTwoTaps, YES, YES, NO),
                   "map query after card close and search tap allowed") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, mapAfterTwoTapsInput, YES, YES, NO),
                   "map submit after card close allowed") ||
            !Check(BBValidAction(@{@"action": @"done"}, placeCard, mapTask,
                                 mapAfterTwoTapsSubmit, YES, YES, NO),
                   "map completion after card close allowed") ||
            !Check(!BBValidAction(tapOther, map, mapTask, @[], YES, YES, NO), "unrelated map tap blocked") ||
            !Check(!BBValidAction(inputPlace, map, mapTask, @[], YES, YES, NO), "map input before focus blocked") ||
            !Check(BBValidAction(inputPlace, focusedMap, mapTask, @[], YES, YES, NO),
                   "map input with focused search allowed") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, mapDirectOne, YES, YES, NO),
                   "map submit after focused input allowed") ||
            !Check(!BBValidAction(@{@"action": @"done"}, searchedMap, mapTask, mapDirectTwo, YES, YES, NO),
                   "search field alone cannot complete map task") ||
            !Check(!BBValidAction(inputPlace, searchedMap, mapTask, @[], YES, YES, NO),
                   "duplicate map query blocked") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, @[], YES, YES, NO),
                   "existing map query can be submitted") ||
            !Check(!BBValidAction(@{@"action": @"done"}, resultsMap, mapTask, @[], YES, YES, NO),
                   "search suggestion and directions cannot complete map task") ||
            !Check(BBValidAction(@{@"action": @"done"}, placeCard, mapTask, @[], YES, YES, NO),
                   "localized place card accepted") ||
            !Check(BBValidAction(@{@"action": @"done"}, fishermanCard,
                                 @"在地图搜索渔人码头", @[], YES, YES, NO),
                   "known English place card accepted") ||
            !Check(!BBValidAction(@{@"action": @"done"}, staleCard,
                                  @"在地图搜索加州科学院", @[inputPlace, enter], YES, YES, NO),
                   "stale card with searching text rejected") ||
            !Check(BBValidAction(academyTap, academySuggestion, @"在地图搜索加州科学院",
                                 @[closeOldCard, tapSearch, academyInput], YES, YES, NO),
                   "exact localized map suggestion allowed") ||
            !Check(BBValidAction(academyRowTap, academySuggestion, @"在地图搜索加州科学院",
                                 @[closeOldCard, tapSearch, academyInput], YES, YES, NO),
                   "matching suggestion row allowed below OCR title") ||
            !Check(BBValidAction(@{@"action": @"tap", @"x": @190, @"y": @522}, islandSuggestion,
                                 @"在地图搜索Alcatraz Island", @[], YES, YES, NO),
                   "existing exact lower suggestion can be selected") ||
            !Check(BBValidAction(@{@"action": @"tap", @"x": @190, @"y": @522}, islandSuggestion,
                                 @"在地图搜索Alcatraz Island", @[tapSearch], YES, YES, NO),
                   "exact suggestion can be selected after focusing existing query") ||
            !Check([BBMapFixedSuggestionAction(islandSuggestion, @"Alcatraz Island")[@"action"] isEqualToString:@"tap"] &&
                   [BBMapFixedSuggestionAction(islandSuggestion, @"Alcatraz Island")[@"y"] doubleValue] < 300,
                   "fixed map suggestion skips obscured first row and picks a visible exact place") ||
            !Check(BBMapFixedSuggestionAction(islandSuggestion, @"Golden Gate Bridge") == nil,
                   "fixed map suggestion refuses a different query") ||
            !Check([BBMapFixedSuggestionAction(towerSuggestion, @"Coit Tower")[@"action"] isEqualToString:@"tap"],
                   "shorter exact place name remains selectable") ||
            !Check([BBMapFixedSuggestionAction(pierSuggestion, @"PIER 39")[@"action"] isEqualToString:@"tap"],
                   "suggestion title matching ignores display case") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @190, @"y": @400}, islandSuggestion,
                                  @"在地图搜索Alcatraz Island", @[], YES, YES, NO),
                   "Search Nearby candidate is excluded") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @190, @"y": @580}, islandSuggestion,
                                  @"在地图搜索Alcatraz Island", @[], YES, YES, NO),
                   "Search results container cannot authorize a tap") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @196, @"y": @92}, academySuggestion,
                                  @"在地图搜索加州科学院", @[academyInput], YES, YES, NO),
                   "search field tap blocked while suggestion visible") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @196, @"y": @370}, academySuggestion,
                                  @"在地图搜索加州科学院", @[academyInput], YES, YES, NO),
                   "directions area blocked while search suggestion visible") ||
            !Check(!BBValidAction(academyTap, academySuggestion, @"在地图搜索金门大桥",
                                  @[inputPlace], YES, YES, NO),
                   "different map suggestion blocked") ||
            !Check(BBValidAction(@{@"action": @"done"}, academyCard,
                                 @"在地图搜索加州科学院", @[academyInput, academyTap], YES, YES, NO),
                   "localized map suggestion completion verified") ||
            !Check(BBValidAction(@{@"action": @"done"}, tower3DCard,
                                 @"在地图搜索Coit Tower", @[], YES, YES, NO),
                   "3D landmark map label and exact card verify completion") ||
            !Check(!BBValidAction(@{@"action": @"done"}, tower3DCard,
                                  @"在地图搜索Alcatraz Island", @[], YES, YES, NO),
                   "3D landmark card does not verify a different query") ||
            !Check(!BBValidAction(@{@"action": @"done"}, placeCard,
                                  @"在地图搜索其它地点", @[], YES, YES, NO),
                   "different place card rejected") ||
            !Check(BBValidAction(inputPlace, focusedMap, mapTask, mapOne, YES, YES, NO), "exact map query allowed") ||
            !Check(!BBValidAction(@{@"action": @"input_text", @"text": @"别的地点"},
                                  focusedMap, mapTask, mapOne, YES, YES, NO), "different map query blocked") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, mapTwo, YES, YES, NO), "map search submit allowed") ||
            !Check(!BBValidAction(enter, Observation(@"com.apple.Maps", NO, focusedUI, @{}),
                                  mapTask, mapTwo, YES, YES, NO), "submit without visible query blocked") ||
            !Check(!BBValidAction(tapOther, searchedMap, mapTask, mapThree, YES, YES, NO), "navigation tap blocked") ||
            !Check(BBValidAction(@{@"action": @"done"}, placeCard, mapTask, mapThree, YES, YES, NO),
                   "verified map card after submit allowed") ||
            !Check(!BBValidAction(@{@"action": @"done"},
                                  Observation(@"com.apple.Maps", NO, focusedUI, @{}),
                                  mapTask, mapThree, YES, YES, NO),
                   "map completion without visible query blocked")) return 1;

        NSDictionary *noteListUI = @{@"elements": @[
            @{@"text": @"新建备忘录", @"visible_rect": @{@"x": @300, @"y": @50, @"width": @60, @"height": @40}},
            @{@"text": @"删除备忘录", @"visible_rect": @{@"x": @250, @"y": @300, @"width": @100, @"height": @40}}]};
        NSDictionary *noteEditorUI = @{@"elements": @[
            @{@"text": @"Notes", @"visible_rect": @{@"x": @20, @"y": @48, @"width": @44, @"height": @44}},
            @{@"text": @"完成", @"visible_rect": @{@"x": @350, @"y": @50, @"width": @50, @"height": @40}},
            @{@"text": @"October 30, 2026 at 15:28", @"aliases": @[@"Timestamp", @"Created", @"Edited"],
              @"visible_rect": @{@"x": @0, @"y": @84, @"width": @414, @"height": @18}},
            @{@"text": @"Note", @"visible_rect": @{@"x": @0, @"y": @0, @"width": @414, @"height": @449}},
            @{@"text": @"return", @"visible_rect": @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *unfocusedNoteUI = @{@"elements": @[
            @{@"text": @"October 30, 2026 at 17:24", @"aliases": @[@"Timestamp", @"Created", @"Edited"],
              @"visible_rect": @{@"x": @0, @"y": @84, @"width": @414, @"height": @18}},
            @{@"text": @"Note", @"visible_rect": @{@"x": @0, @"y": @0, @"width": @414, @"height": @794}},
            @{@"text": @"New note", @"visible_rect": @{@"x": @343, @"y": @825, @"width": @38, @"height": @38}}]};
        NSDictionary *noteList = Observation(@"com.apple.mobilenotes", NO, noteListUI, @{});
        NSDictionary *persistedNoteList = Observation(@"com.apple.mobilenotes", NO,
            @{@"elements": @[
                @{@"text": @"新建备忘录", @"visible_rect": @{@"x": @300, @"y": @50, @"width": @60, @"height": @40}},
                @{@"text": @"测试内容, modified 18:30, No additional text", @"visible_rect":
                  @{@"x": @20, @"y": @200, @"width": @374, @"height": @60}}]}, @{});
        NSDictionary *changingNoteList = Observation(@"com.apple.mobilenotes", NO,
            @{@"elements": @[
                @{@"text": @"新建备忘录", @"visible_rect": @{@"x": @300, @"y": @50, @"width": @60, @"height": @40}},
                @{@"text": @"列表刚更新", @"visible_rect": @{@"x": @20, @"y": @150, @"width": @200, @"height": @40}}]}, @{});
        NSDictionary *blankNote = Observation(@"com.apple.mobilenotes", NO, noteEditorUI, @{});
        NSDictionary *unfocusedNote = Observation(@"com.apple.mobilenotes", NO, unfocusedNoteUI,
                                                  @{@"texts": @[]});
        NSDictionary *nonblankNote = Observation(@"com.apple.mobilenotes", NO, unfocusedNoteUI,
            @{@"texts": @[@{@"text": @"Existing content", @"rect": @{@"y": @180}}]});
        NSDictionary *note = Observation(@"com.apple.mobilenotes", NO, noteEditorUI, @{@"text": @"测试内容"});
        NSString *noteTask = @"新建备忘录：测试内容";
        __block NSUInteger noteObserveCount = 0, noteActCount = 0;
        BBNoteBridgeRequest fakeNoteBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                noteObserveCount++;
                NSMutableDictionary *result = [noteList mutableCopy];
                result[@"ok"] = @YES;
                result[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
                result[@"observation_id"] = [NSString stringWithFormat:@"note-%lu", (unsigned long)noteObserveCount];
                return result;
            }
            if ([request[@"op"] isEqualToString:@"act"]) {
                noteActCount++;
                return [request[@"observation_id"] isEqualToString:@"note-2"] &&
                    [request[@"action"] isEqualToString:@"tap"] ? @{@"ok": @YES} : @{@"ok": @NO};
            }
            return @{@"ok": @NO};
        };
        NSDictionary *firstNoteStep = BBNoteStep(noteTask, @[], fakeNoteBridge);
        if (!Check([firstNoteStep[@"ok"] boolValue] && ![firstNoteStep[@"done"] boolValue] &&
                   [firstNoteStep[@"action"][@"action"] isEqualToString:@"tap"] &&
                   noteObserveCount == 2 && noteActCount == 1,
                   "harness note step observes twice and executes one validated action")) return 1;
        __block NSUInteger delayedNoteReads = 0, delayedNoteActs = 0;
        BBNoteBridgeRequest delayedNoteBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                delayedNoteReads++;
                NSDictionary *state = delayedNoteReads == 1 ?
                    Observation(@"com.apple.mobilenotes", NO, @{@"elements": @[]}, @{}) : noteList;
                return StepObservation(state,
                    [NSString stringWithFormat:@"delayed-note-%lu", (unsigned long)delayedNoteReads]);
            }
            if ([request[@"op"] isEqualToString:@"act"] &&
                [request[@"action"] isEqualToString:@"tap"]) {
                delayedNoteActs++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        NSDictionary *delayedNoteStep = BBNoteStep(noteTask,
            @[@{@"action": @"launch_app", @"bundle_id": @"com.apple.mobilenotes"}],
            delayedNoteBridge);
        if (!Check([delayedNoteStep[@"ok"] boolValue] &&
                   [delayedNoteStep[@"action"][@"action"] isEqualToString:@"tap"] &&
                   delayedNoteReads >= 3 && delayedNoteActs == 1,
                   "note harness waits for list controls after launching Notes")) return 1;
        __block NSUInteger changedReads = 0, rejectedNoteActCount = 0;
        BBNoteBridgeRequest changedNoteBridge = ^NSDictionary *(NSDictionary *request) {
            if ([request[@"op"] isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([request[@"op"] isEqualToString:@"observe"]) {
                NSMutableDictionary *result = [noteList mutableCopy];
                changedReads++;
                if (changedReads == 2) result[@"frontmost_app"] = @{@"bundleId": @"com.apple.Maps"};
                result[@"ok"] = @YES;
                result[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
                result[@"observation_id"] = [NSString stringWithFormat:@"changed-%lu", (unsigned long)changedReads];
                return result;
            }
            if ([request[@"op"] isEqualToString:@"act"]) rejectedNoteActCount++;
            return @{@"ok": @NO};
        };
        NSDictionary *changedNoteStep = BBNoteStep(noteTask, @[], changedNoteBridge);
        if (!Check([changedNoteStep[@"error"] isEqualToString:@"fresh_state"] &&
                   rejectedNoteActCount == 0,
                   "harness note step refuses a foreground change before acting")) return 1;
        if (!Check(BBUnlockedObservation(note), "unlocked observation accepted") ||
            !Check(BBNoteEditorReady(blankNote), "new note editor recognized") ||
            !Check(!BBUnlockedObservation(Observation(@"com.apple.mobilenotes", YES, noteListUI, nil)),
                   "locked observation rejected before model")) return 1;
        NSDictionary *newNote = @{@"action": @"tap", @"x": @320, @"y": @70};
        NSDictionary *focusNote = @{@"action": @"tap", @"x": @82.8, @"y": @179.2};
        NSDictionary *noteText = @{@"action": @"input_text", @"text": @"测试内容"};
        NSDictionary *doneTap = @{@"action": @"tap", @"x": @370, @"y": @70};
        NSDictionary *backTap = @{@"action": @"tap", @"x": @42, @"y": @70};
        NSArray *noteOne = @[newNote], *noteTwo = @[newNote, noteText];
        NSArray *noteThree = @[newNote, noteText, doneTap];
        NSArray *noteFour = @[newNote, noteText, doneTap, backTap];
        NSArray *noteFocused = @[newNote, focusNote];
        NSArray *noteFocusedTyped = @[newNote, focusNote, noteText];
        NSArray *noteFocusedDone = @[newNote, focusNote, noteText, doneTap];
        NSArray *noteFocusedListed = @[newNote, focusNote, noteText, doneTap, backTap];
        NSArray *noteJourney = @[noteList, blankNote, note, note, persistedNoteList];
        NSArray *expectedJourneyActions = @[@"tap", @"input_text", @"tap", @"tap"];
        __block NSUInteger journeyStage = 0, journeyObservation = 0;
        BBNoteBridgeRequest journeyBridge = ^NSDictionary *(NSDictionary *request) {
            NSString *op = request[@"op"];
            if ([op isEqualToString:@"wake_lease"]) return @{@"ok": @YES};
            if ([op isEqualToString:@"observe"]) {
                NSMutableDictionary *result = [noteJourney[MIN(journeyStage, 4)] mutableCopy];
                result[@"ok"] = @YES;
                result[@"timestamp"] = @(NSDate.date.timeIntervalSince1970);
                result[@"observation_id"] = [NSString stringWithFormat:@"journey-%lu", (unsigned long)++journeyObservation];
                return result;
            }
            if ([op isEqualToString:@"act"] && journeyStage < 4 &&
                [request[@"action"] isEqualToString:expectedJourneyActions[journeyStage]] &&
                [request[@"observation_id"] isEqualToString:
                    [NSString stringWithFormat:@"journey-%lu", (unsigned long)journeyObservation]]) {
                journeyStage++;
                return @{@"ok": @YES};
            }
            return @{@"ok": @NO};
        };
        NSMutableArray *journeyHistory = [NSMutableArray array];
        NSDictionary *journeyResult = nil;
        for (NSUInteger step = 0; step < 5; step++) {
            journeyResult = BBNoteStep(noteTask, journeyHistory, journeyBridge);
            if (![journeyResult[@"ok"] boolValue] || [journeyResult[@"done"] boolValue]) break;
            [journeyHistory addObject:journeyResult[@"action"]];
        }
        if (!Check([journeyResult[@"ok"] boolValue] && [journeyResult[@"done"] boolValue] &&
                   journeyStage == 4 && journeyHistory.count == 4 && journeyObservation == 9,
                   "harness note steps create and verify one note through a full local journey")) return 1;
        NSDictionary *fixedNewNote = BBFixedNoteAction(noteTask, noteList, @[]);
        if (!Check([fixedNewNote[@"action"] isEqualToString:@"tap"] &&
                   [fixedNewNote[@"x"] doubleValue] == 330 && [fixedNewNote[@"y"] doubleValue] == 70,
                   "fixed note planner taps exact new note control") ||
            !Check(BBFixedNoteAction(noteTask, persistedNoteList, @[])[@"error"] != nil,
                   "duplicate title is refused before creation") ||
            !Check([BBFixedNoteAction(noteTask, blankNote, noteOne)[@"action"] isEqualToString:@"input_text"],
                   "fixed note planner enters exact content") ||
            !Check([BBFixedNoteAction(noteTask, note, noteTwo)[@"action"] isEqualToString:@"tap"],
                   "fixed note planner taps Done after content") ||
            !Check([BBFixedNoteAction(noteTask, note, noteThree)[@"action"] isEqualToString:@"tap"],
                   "fixed note planner returns to list after Done") ||
            !Check([BBFixedNoteAction(noteTask, persistedNoteList, noteFour)[@"action"] isEqualToString:@"done"],
                   "fixed note planner completes only after list persistence") ||
            !Check(BBFixedNoteAction(noteTask, noteList, noteFour)[@"error"] != nil,
                   "missing new note in list cannot complete") ||
            !Check([BBFixedNoteAction(noteTask, unfocusedNote, noteOne)[@"action"] isEqualToString:@"tap"],
                   "fixed note planner focuses a verified blank canvas") ||
            !Check([BBFixedNoteAction(noteTask, blankNote, noteFocused)[@"action"] isEqualToString:@"input_text"],
                   "fixed note planner types after focus") ||
            !Check([BBFixedNoteAction(noteTask, note, noteFocusedTyped)[@"action"] isEqualToString:@"tap"],
                   "fixed note planner taps Done after focused typing") ||
            !Check([BBFixedNoteAction(noteTask, note, noteFocusedDone)[@"action"] isEqualToString:@"tap"],
                   "focused sequence also returns to list") ||
            !Check([BBFixedNoteAction(noteTask, persistedNoteList, noteFocusedListed)[@"action"] isEqualToString:@"done"],
                   "focused sequence verifies list persistence") ||
            !Check(BBFixedNoteAction(noteTask, nonblankNote, noteOne)[@"error"] != nil,
                   "fixed note planner refuses existing body text") ||
            !Check(BBFixedNoteAction(noteTask, blankNote, @[])[@"error"] != nil,
                   "fixed note planner refuses existing editor without new note action")) return 1;
        if (!Check(BBValidAction(newNote, noteList, noteTask, @[], YES, NO, YES), "new note tap allowed") ||
            !Check(BBValidAction(newNote, changingNoteList, noteTask, @[], YES, NO, YES),
                   "new note control remains valid while list content changes") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @280, @"y": @320},
                                  noteList, noteTask, @[], YES, NO, YES), "delete tap blocked") ||
            !Check(BBValidAction(noteText, blankNote, noteTask, noteOne, YES, NO, YES), "exact note text allowed") ||
            !Check(BBValidAction(focusNote, unfocusedNote, noteTask, noteOne, YES, NO, YES),
                   "blank new note focus allowed") ||
            !Check(!BBValidAction(focusNote, nonblankNote, noteTask, noteOne, YES, NO, YES),
                   "existing note body focus blocked") ||
            !Check(BBValidAction(noteText, blankNote, noteTask, noteFocused, YES, NO, YES),
                   "input after blank focus allowed") ||
            !Check(BBValidAction(doneTap, note, noteTask, noteFocusedTyped, YES, NO, YES),
                   "Done after focused input allowed") ||
            !Check(BBValidAction(backTap, note, noteTask, noteFocusedDone, YES, NO, YES),
                   "focused note back-to-list allowed") ||
            !Check(BBValidAction(@{@"action": @"done"}, persistedNoteList, noteTask,
                                 noteFocusedListed, YES, NO, YES),
                   "focused note completion requires list row") ||
            !Check(!BBValidAction(@{@"action": @"input_text", @"text": @"别的内容"},
                                  blankNote, noteTask, noteOne, YES, NO, YES), "different note text blocked") ||
            !Check(!BBValidAction(noteText, note, noteTask, noteOne, YES, NO, YES),
                   "duplicate note text blocked") ||
            !Check(BBValidAction(doneTap, note, noteTask, noteTwo, YES, NO, YES), "note Done allowed") ||
            !Check(!BBValidAction(doneTap, blankNote, noteTask, noteTwo, YES, NO, YES),
                   "empty note cannot be marked Done") ||
            !Check(BBValidAction(backTap, note, noteTask, noteThree, YES, NO, YES),
                   "note back-to-list allowed after Done") ||
            !Check(BBValidAction(@{@"action": @"done"}, persistedNoteList, noteTask,
                                 noteFour, YES, NO, YES),
                   "note completion with persisted list row allowed") ||
            !Check(!BBValidAction(@{@"action": @"done"}, noteList, noteTask,
                                  noteFour, YES, NO, YES),
                   "note completion without persisted row blocked") ||
            !Check(!BBValidAction(@{@"action": @"done"}, note, noteTask, noteTwo, YES, NO, YES),
                   "premature note completion blocked") ||
            !Check(!BBValidAction(newNote, Observation(@"com.apple.mobilenotes", YES, noteListUI, nil),
                                  noteTask, @[], YES, NO, YES), "locked action blocked")) return 1;
        puts("PASS: native map and note action policy");
        return 0;
    }
}
