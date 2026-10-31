#import <Foundation/Foundation.h>
#import "../bridge/BBObservationClock.h"

// Exercise the exact on-device policy implementation without making bridge or model calls.
#define main beanbaod_entry
#include "../agent-native/beanbaod.m"
#undef main
#include "../agent-native/AgentService.m"

// The policy fixture includes the Objective-C entry point without linking the
// Swift harness; harness behavior has its own Swift package tests.
int32_t BBRunHarnessMock(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessNote(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessMap(const char *task) { (void)task; return 1; }
int32_t BBRunHarnessMapMock(const char *task) { (void)task; return 1; }

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
        if (!Check(BBObservationIsFresh(100, 109.9),
                   "recent monotonic observation remains valid") ||
            !Check(!BBObservationIsFresh(100, 110.1),
                   "expired monotonic observation is rejected") ||
            !Check(!BBObservationIsFresh(100, 99),
                   "clock rollback cannot revive an observation") ||
            !Check(!BBObservationIsFresh(NAN, 101),
                   "invalid observation time is rejected")) return 1;
        NSTimeInterval testNow = NSDate.date.timeIntervalSince1970;
        if (!Check(BBRecentObservation(@{@"timestamp": @(testNow - 1)}),
                   "recent Agent observation remains valid") ||
            !Check(!BBRecentObservation(@{@"timestamp": @(testNow + 60)}),
                   "future Agent observation is rejected") ||
            !Check(!BBRecentObservation(@{@"timestamp": @(testNow - 60)}),
                   "stale Agent observation is rejected")) return 1;
        BBState = [BBServiceState new];
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
        for (NSString *task in @[@"打开设置", @"打开备忘录", @"打开地图", @"打开通讯录"])
            if (!Check(BBUsesTextHarness(task), "fixed text opens use Palmino harness")) return 1;
        if (!Check(!BBUsesTextHarness(@"在地图搜索金门大桥") &&
                   !BBUsesTextHarness(@"新建备忘录：测试内容"),
                   "map search and note creation have separate bounded workflows")) return 1;
        char *invalidNoteJSON = BBNoteStepJSON("打开地图", "[]");
        NSDictionary *invalidNote = invalidNoteJSON ?
            [NSJSONSerialization JSONObjectWithData:
                [[NSString stringWithUTF8String:invalidNoteJSON] dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil] : nil;
        free(invalidNoteJSON);
        if (!Check([invalidNote[@"error"] isEqualToString:@"invalid_task"],
                   "note step rejects an unsupported task before Bridge access")) return 1;
        char *invalidMapJSON = BBMapMockStepJSON("打开地图", "[]");
        NSDictionary *invalidMap = invalidMapJSON ?
            [NSJSONSerialization JSONObjectWithData:
                [[NSString stringWithUTF8String:invalidMapJSON] dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil] : nil;
        free(invalidMapJSON);
        if (!Check([invalidMap[@"error"] isEqualToString:@"invalid_task"],
                   "mock map C entry rejects an unsupported task before Bridge access")) return 1;
        if (!Check([BBNormalizeTask(@"  打开地图。 ") isEqualToString:@"打开地图"],
                   "speech punctuation normalization") ||
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
            !Check([BBCompletionMessage(@"在地图搜索加州科学院") isEqualToString:@"地图搜索已完成"],
                   "map completion summary is fixed") ||
            !Check([BBCompletionMessage(@"新建备忘录：测试内容") isEqualToString:@"备忘录已创建"],
                   "note completion summary is fixed") ||
            !Check([BBFailureMessage(@"模型请求或输出失败：private model text")
                    isEqualToString:@"模型请求或输出失败，请稍后重试"],
                   "model error does not expose child output") ||
            !Check([BBFailureMessage(@"unexpected private output")
                    isEqualToString:@"任务未完成，请检查界面后重试"],
                   "unknown error does not expose child output") ||
            !Check([BBFailureMessage(@"备忘录界面状态不符合安全条件")
                    isEqualToString:@"备忘录界面状态不符合安全条件，已停止"],
                   "note state error is specific and fixed") ||
            !Check([BBFailureMessage(@"防自动锁屏不可用，已停止任务")
                    isEqualToString:@"防自动锁屏不可用，已停止任务"],
                   "wake lease failure has a fixed message") ||
            !Check([BBFailureMessage(@"未能确认地图已显示输入地点")
                    isEqualToString:@"未能确认地图已显示输入地点，已停止"],
                   "unverified map input has a fixed message") ||
            !Check(BBFreshUICompatible(@"launch_app", NO, NO, NO, NO),
                   "allowlisted app launch tolerates source UI status changes") ||
            !Check(!BBFreshUICompatible(@"tap", NO, NO, NO, NO),
                   "coordinate action still requires matching source UI") ||
            !Check([BBAllowedTarget(@"新建备忘录：测试内容") isEqualToString:@"备忘录"],
                   "note task accepted") ||
            !Check(BBTaskModelAllowed(@"新建备忘录：测试内容", @"mock"),
                   "local note task accepts mock mode") ||
            !Check(BBTaskModelAllowed(@"新建备忘录：测试内容", @"claude"),
                   "local note task also accepts Claude selection") ||
            !Check([BBAllowedTarget(@"打开通讯录") isEqualToString:@"通讯录"],
                   "Contacts opens only through the exact task") ||
            !Check([BBRequestedApp(@"打开通讯录") isEqualToString:@"com.apple.MobileAddressBook"],
                   "Contacts targets the installed bundle") ||
            !Check(BBTaskModelAllowed(@"打开通讯录", @"mock") &&
                   !BBTaskModelAllowed(@"打开通讯录", @"claude"),
                   "Contacts stays local and never sends its UI to Claude") ||
            !Check([BBMockAction(@"打开通讯录",
                    Observation(@"dev.beanbao.app", NO, @{}, @{}), 0)[@"bundle_id"]
                    isEqualToString:@"com.apple.MobileAddressBook"],
                   "mock action launches Contacts") ||
            !Check(BBTaskModelAllowed(@"在地图搜索金门大桥", @"mock") &&
                   BBTaskModelAllowed(@"在地图搜索金门大桥", @"claude"),
                   "map search accepts local and Claude planning") ||
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
        NSDictionary *searchedMap = Observation(@"com.apple.Maps", NO, focusedUI, @{@"text": @"金门大桥"});
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
                   mapJourneyModelCalls == 3 && mapJourneyScreenshotRequested,
                   "map harness completes a full bounded local search journey")) return 1;
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
