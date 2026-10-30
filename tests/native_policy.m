#import <Foundation/Foundation.h>

// Exercise the exact on-device policy implementation without making bridge or model calls.
#define main beanbaod_entry
#include "../agent-native/beanbaod.m"
#undef main
#include "../agent-native/AgentService.m"

static NSDictionary *Observation(NSString *app, BOOL locked, NSDictionary *ui, NSDictionary *ocr) {
    return @{@"device_state": @{@"locked_known": @YES, @"locked": @(locked),
                               @"screen_on_known": @YES, @"screen_on": @YES},
             @"frontmost_app": @{@"bundleId": app},
             @"screen": @{@"width": @414, @"height": @896},
             @"ui": ui ?: @{}, @"ocr": ocr ?: @{}};
}

static BOOL Check(BOOL condition, const char *message) {
    if (!condition) fprintf(stderr, "FAIL: %s\n", message);
    return condition;
}

int main(void) {
    @autoreleasepool {
        if (!Check([BBNormalizeTask(@"  打开地图。 ") isEqualToString:@"打开地图"],
                   "speech punctuation normalization") ||
            !Check([BBNormalizeTask(@"新建备忘录：测试内容。") isEqualToString:@"新建备忘录：测试内容。"],
                   "note text preserved") ||
            !Check([BBAllowedTarget(@"新建备忘录：测试内容") isEqualToString:@"备忘录"],
                   "note task accepted") ||
            !Check(BBAllowedTarget(@"新建备忘录：短") == nil, "short note task refused") ||
            !Check(BBAllowedTarget(@"打开设置并删除账户") == nil, "unsafe extra instruction refused")) return 1;
        NSDictionary *mapUI = @{@"elements": @[@{@"text": @"搜索地图", @"visible_rect":
            @{@"x": @20, @"y": @200, @"width": @300, @"height": @50}}]};
        NSDictionary *map = Observation(@"com.apple.Maps", NO, mapUI, @{@"text": @"金门大桥"});
        NSString *mapTask = @"在地图搜索金门大桥";
        NSDictionary *tapSearch = @{@"action": @"tap", @"x": @100, @"y": @220};
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
        NSDictionary *resultsUI = @{@"elements": @[
            @{@"text": @"Search field"}, @{@"text": @"金门大桥, Search Nearby"},
            @{@"text": @"Directions"}]};
        NSDictionary *resultsMap = Observation(@"com.apple.Maps", NO, resultsUI, @{});
        NSArray *mapDirectOne = @[inputPlace], *mapDirectTwo = @[inputPlace, enter];
        if (!Check(BBValidAction(tapSearch, map, mapTask, @[], YES, YES, NO), "map search tap allowed") ||
            !Check(!BBValidAction(tapOther, map, mapTask, @[], YES, YES, NO), "unrelated map tap blocked") ||
            !Check(!BBValidAction(inputPlace, map, mapTask, @[], YES, YES, NO), "map input before focus blocked") ||
            !Check(BBValidAction(inputPlace, focusedMap, mapTask, @[], YES, YES, NO),
                   "map input with focused search allowed") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, mapDirectOne, YES, YES, NO),
                   "map submit after focused input allowed") ||
            !Check(BBValidAction(@{@"action": @"done"}, searchedMap, mapTask, mapDirectTwo, YES, YES, NO),
                   "focused map completion allowed") ||
            !Check(!BBValidAction(inputPlace, searchedMap, mapTask, @[], YES, YES, NO),
                   "duplicate map query blocked") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, @[], YES, YES, NO),
                   "existing map query can be submitted") ||
            !Check(BBValidAction(@{@"action": @"done"}, resultsMap, mapTask, @[], YES, YES, NO),
                   "already visible map result accepted") ||
            !Check(BBValidAction(inputPlace, focusedMap, mapTask, mapOne, YES, YES, NO), "exact map query allowed") ||
            !Check(!BBValidAction(@{@"action": @"input_text", @"text": @"别的地点"},
                                  focusedMap, mapTask, mapOne, YES, YES, NO), "different map query blocked") ||
            !Check(BBValidAction(enter, searchedMap, mapTask, mapTwo, YES, YES, NO), "map search submit allowed") ||
            !Check(!BBValidAction(enter, Observation(@"com.apple.Maps", NO, focusedUI, @{}),
                                  mapTask, mapTwo, YES, YES, NO), "submit without visible query blocked") ||
            !Check(!BBValidAction(tapOther, searchedMap, mapTask, mapThree, YES, YES, NO), "navigation tap blocked") ||
            !Check(BBValidAction(@{@"action": @"done"}, searchedMap, mapTask, mapThree, YES, YES, NO),
                   "map completion after submit allowed") ||
            !Check(!BBValidAction(@{@"action": @"done"},
                                  Observation(@"com.apple.Maps", NO, focusedUI, @{}),
                                  mapTask, mapThree, YES, YES, NO),
                   "map completion without visible query blocked")) return 1;

        NSDictionary *noteListUI = @{@"elements": @[
            @{@"text": @"新建备忘录", @"visible_rect": @{@"x": @300, @"y": @50, @"width": @60, @"height": @40}},
            @{@"text": @"删除备忘录", @"visible_rect": @{@"x": @250, @"y": @300, @"width": @100, @"height": @40}}]};
        NSDictionary *noteEditorUI = @{@"elements": @[
            @{@"text": @"完成", @"visible_rect": @{@"x": @350, @"y": @50, @"width": @50, @"height": @40}},
            @{@"text": @"October 30, 2026 at 15:28", @"aliases": @[@"Timestamp", @"Created", @"Edited"],
              @"visible_rect": @{@"x": @0, @"y": @84, @"width": @414, @"height": @18}},
            @{@"text": @"Note", @"visible_rect": @{@"x": @0, @"y": @0, @"width": @414, @"height": @449}},
            @{@"text": @"return", @"visible_rect": @{@"x": @309, @"y": @770, @"width": @100, @"height": @56}}]};
        NSDictionary *noteList = Observation(@"com.apple.mobilenotes", NO, noteListUI, @{});
        NSDictionary *blankNote = Observation(@"com.apple.mobilenotes", NO, noteEditorUI, @{});
        NSDictionary *note = Observation(@"com.apple.mobilenotes", NO, noteEditorUI, @{@"text": @"测试内容"});
        NSString *noteTask = @"新建备忘录：测试内容";
        if (!Check(BBUnlockedObservation(note), "unlocked observation accepted") ||
            !Check(BBNoteEditorReady(blankNote), "new note editor recognized") ||
            !Check(!BBUnlockedObservation(Observation(@"com.apple.mobilenotes", YES, noteListUI, nil)),
                   "locked observation rejected before model")) return 1;
        NSDictionary *newNote = @{@"action": @"tap", @"x": @320, @"y": @70};
        NSDictionary *noteText = @{@"action": @"input_text", @"text": @"测试内容"};
        NSDictionary *doneTap = @{@"action": @"tap", @"x": @370, @"y": @70};
        NSArray *noteOne = @[newNote], *noteTwo = @[newNote, noteText];
        NSArray *noteThree = @[newNote, noteText, doneTap];
        if (!Check(BBValidAction(newNote, noteList, noteTask, @[], YES, NO, YES), "new note tap allowed") ||
            !Check(!BBValidAction(@{@"action": @"tap", @"x": @280, @"y": @320},
                                  noteList, noteTask, @[], YES, NO, YES), "delete tap blocked") ||
            !Check(BBValidAction(noteText, blankNote, noteTask, noteOne, YES, NO, YES), "exact note text allowed") ||
            !Check(!BBValidAction(@{@"action": @"input_text", @"text": @"别的内容"},
                                  blankNote, noteTask, noteOne, YES, NO, YES), "different note text blocked") ||
            !Check(!BBValidAction(noteText, note, noteTask, noteOne, YES, NO, YES),
                   "duplicate note text blocked") ||
            !Check(BBValidAction(doneTap, note, noteTask, noteTwo, YES, NO, YES), "note Done allowed") ||
            !Check(!BBValidAction(doneTap, blankNote, noteTask, noteTwo, YES, NO, YES),
                   "empty note cannot be marked Done") ||
            !Check(BBValidAction(@{@"action": @"done"}, note, noteTask, noteThree, YES, NO, YES),
                   "note completion with visible content allowed") ||
            !Check(!BBValidAction(@{@"action": @"done"}, note, noteTask, noteTwo, YES, NO, YES),
                   "premature note completion blocked") ||
            !Check(!BBValidAction(newNote, Observation(@"com.apple.mobilenotes", YES, noteListUI, nil),
                                  noteTask, @[], YES, NO, YES), "locked action blocked")) return 1;
        puts("PASS: native map and note action policy");
        return 0;
    }
}
