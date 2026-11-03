#import "WorkflowSessionsViewController.h"
#import "WorkflowDetailViewController.h"
#import "AgentClient.h"

@interface BBWorkflowSessionsViewController ()
@property(nonatomic, strong) NSArray<NSDictionary *> *workflows;
@property(nonatomic, strong) NSDateFormatter *dates;
@end

@implementation BBWorkflowSessionsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sessions";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 76;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadSessions)
            forControlEvents:UIControlEventValueChanged];
    self.dates = [NSDateFormatter new];
    self.dates.dateStyle = NSDateFormatterMediumStyle;
    self.dates.timeStyle = NSDateFormatterShortStyle;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSessions];
}

- (void)showError:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Could not update session"
        message:message ?: @"Please try again" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)reloadSessions {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": @"list_workflows"});
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.refreshControl endRefreshing];
            if (![reply[@"ok"] boolValue] || ![reply[@"workflows"] isKindOfClass:NSArray.class]) {
                [self showError:reply[@"error"]];
                return;
            }
            self.workflows = reply[@"workflows"];
            [self.tableView reloadData];
        });
    });
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.workflows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.workflows.count ? @"Saved workflows" : @"No saved sessions";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Workflow"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Workflow"];
    NSDictionary *item = self.workflows[indexPath.row];
    NSString *phase = item[@"phase"];
    NSString *kind = item[@"kind"];
    BOOL installRequested = [item[@"install_requested"] boolValue];
    NSString *status = @"Resume";
    if ([phase isEqualToString:@"completed"]) {
        status = @"Completed";
    } else if ([phase isEqualToString:@"running"]) {
        status = @"Interrupted · Resume";
    } else if ([phase isEqualToString:@"waitingForUser"]) {
        if ([kind isEqualToString:@"research_mail_app"]) {
            status = [item[@"mail_queued"] boolValue] ?
                (installRequested ? @"Install selected app" : @"Review app listing") :
                ([item[@"app_installed"] boolValue] ? @"Review email draft" :
                 (installRequested ? @"Review PDF and email; install app" :
                  @"Review PDF, email and app listing"));
        } else if ([kind isEqualToString:@"research_app"]) {
            status = installRequested ? @"Review PDF and install app" :
                @"Review PDF and app listing";
        } else if ([kind isEqualToString:@"app_store"]) {
            status = @"Review app listing";
        } else if ([kind isEqualToString:@"delivery"]) {
            status = @"Continue delivery";
        } else {
            status = @"Review email";
        }
    } else if ([phase isEqualToString:@"needsReconciliation"]) {
        if ([kind isEqualToString:@"delivery"]) status = @"Review delivery action";
        else if ([kind isEqualToString:@"research_mail_app"])
            status = @"Review email and app outcomes";
        else if ([@[@"app_store", @"research_app"] containsObject:kind])
            status = @"Check app installation";
        else status = @"Check Mail";
    }
    cell.textLabel.text = item[@"request"];
    cell.textLabel.numberOfLines = 2;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[item[@"updated_at"] doubleValue]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", status, [self.dates stringFromDate:date]];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDetailDisclosureButton;
    return cell;
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSString *identity = self.workflows[indexPath.row][@"id"];
    if (![[NSUUID alloc] initWithUUIDString:identity]) return;
    BBWorkflowDetailViewController *detail =
        [[BBWorkflowDetailViewController alloc] initWithWorkflowID:identity];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)performOperation:(NSString *)op identity:(NSString *)identity closeOnSuccess:(BOOL)close {
    if (![[NSUUID alloc] initWithUUIDString:identity]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = BBAgentRequest(@{@"op": op, @"workflow_id": identity});
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![reply[@"ok"] boolValue]) { [self showError:reply[@"error"]]; return; }
            if (close) {
                [[NSNotificationCenter defaultCenter] postNotificationName:@"BBWorkflowSelectedNotification"
                    object:nil userInfo:@{@"reply": reply}];
                [self.navigationController popViewControllerAnimated:YES];
            }
            else [self reloadSessions];
        });
    });
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = self.workflows[indexPath.row];
    NSString *identity = item[@"id"];
    NSString *phase = item[@"phase"];
    if (![[NSUUID alloc] initWithUUIDString:identity]) return;
    if ([@[@"completed", @"waitingForUser", @"needsReconciliation"] containsObject:phase]) {
        [self performOperation:@"select_workflow" identity:identity closeOnSuccess:YES];
        return;
    }
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Resume workflow?"
        message:@"BeanBao will continue from its saved checkpoint."
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *action) {
            [self performOperation:@"resume_workflow" identity:identity closeOnSuccess:YES];
        }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
        forRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (style != UITableViewCellEditingStyleDelete) return;
    NSDictionary *item = self.workflows[indexPath.row];
    NSString *identity = item[@"id"];
    UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Delete session?"
        message:@"This removes its report, email draft, and saved progress."
        preferredStyle:UIAlertControllerStyleAlert];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive
        handler:^(__unused UIAlertAction *action) {
            [self performOperation:@"delete_workflow" identity:identity closeOnSuccess:NO];
        }]];
    [self presentViewController:prompt animated:YES completion:nil];
}

@end
