#import "WorkflowDetailViewController.h"
#import "AgentClient.h"

@interface BBWorkflowDetailViewController ()
@property(nonatomic, copy) NSString *workflowID;
@property(nonatomic, strong) NSDictionary *details;
@property(nonatomic, strong) NSDateFormatter *dates;
@end

@implementation BBWorkflowDetailViewController

- (instancetype)initWithWorkflowID:(NSString *)identity {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) _workflowID = [identity copy];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Workflow details";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadDetails)
        forControlEvents:UIControlEventValueChanged];
    self.dates = [NSDateFormatter new];
    self.dates.dateStyle = NSDateFormatterMediumStyle;
    self.dates.timeStyle = NSDateFormatterShortStyle;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadDetails];
}

- (void)reloadDetails {
    NSString *identity = self.workflowID;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"workflow_details", @"workflow_id": identity});
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (![reply[@"ok"] boolValue] || ![reply[@"steps"] isKindOfClass:NSArray.class]) {
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not load workflow"
                    message:reply[@"error"] ?: @"Please try again"
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
                return;
            }
            self.details = reply;
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.details ? 2 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 1;
    NSArray *steps = self.details[@"steps"];
    return MAX(steps.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"Request";
    NSUInteger total = [self.details[@"total_steps"] unsignedIntegerValue];
    NSUInteger shown = [self.details[@"steps"] count];
    return total > shown ? [NSString stringWithFormat:@"Latest %lu of %lu steps",
        (unsigned long)shown, (unsigned long)total] : @"Steps";
}

static NSString *BBStepName(NSString *tool) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"web_search": @"Search the web", @"report_compose": @"Compose report",
        @"pdf_render": @"Create PDF", @"mail_prepare": @"Prepare email draft",
        @"app_lookup": @"Find app", @"app_prepare": @"Save app listing",
        @"delivery_choose": @"Choose next action", @"delivery_execute": @"Perform delivery action",
        @"delivery_review_cart": @"Review cart", @"delivery_review_checkout": @"Review checkout"
    };
    return names[tool] ?: @"Workflow step";
}

static NSString *BBStepState(NSString *state) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"running": @"Running", @"completed": @"Completed",
        @"failed": @"Failed", @"needsReconciliation": @"Needs review",
        @"proposed": @"Proposed"
    };
    return names[state] ?: @"Unknown";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuse = indexPath.section == 0 ? @"Request" : @"Step";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
        reuseIdentifier:reuse];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (indexPath.section == 0) {
        cell.textLabel.text = self.details[@"request"];
        NSString *phase = self.details[@"phase"];
        cell.detailTextLabel.text = [phase isEqualToString:@"completed"] ? @"Completed" :
            ([phase isEqualToString:@"waitingForUser"] ? @"Waiting for you" :
             ([phase isEqualToString:@"needsReconciliation"] ? @"Needs review" :
              ([phase isEqualToString:@"running"] ? @"In progress" : @"Stopped")));
        return cell;
    }
    NSArray *steps = self.details[@"steps"];
    if (!steps.count) {
        cell.textLabel.text = @"No steps recorded";
        cell.detailTextLabel.text = nil;
        return cell;
    }
    NSDictionary *step = steps[indexPath.row];
    NSString *title = [step[@"title"] isKindOfClass:NSString.class] ? step[@"title"] : nil;
    cell.textLabel.text = [NSString stringWithFormat:@"%ld. %@", (long)indexPath.row + 1,
        title ?: BBStepName(step[@"tool"])];
    NSTimeInterval timestamp = [step[@"updated_at"] doubleValue];
    NSString *when = timestamp > 0 ? [self.dates stringFromDate:
        [NSDate dateWithTimeIntervalSince1970:timestamp]] : nil;
    NSString *state = BBStepState(step[@"state"]);
    cell.detailTextLabel.text = when ? [NSString stringWithFormat:@"%@ · %@", state, when] : state;
    return cell;
}

@end
