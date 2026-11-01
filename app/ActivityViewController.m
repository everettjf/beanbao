#import "ActivityViewController.h"
#import "ActivityStore.h"

@interface BBActivityViewController ()
@property(nonatomic, strong) NSArray<NSDictionary *> *items;
@property(nonatomic, strong) NSDateFormatter *dateFormatter;
@end

@implementation BBActivityViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Activity";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.rowHeight = 70;
    self.dateFormatter = [NSDateFormatter new];
    self.dateFormatter.dateStyle = NSDateFormatterMediumStyle;
    self.dateFormatter.timeStyle = NSDateFormatterShortStyle;
    UILabel *footer = [UILabel new];
    footer.text = @"Only the app, outcome, and time are shown. Requests, note contents, screenshots, and model replies are not saved here.";
    footer.font = [UIFont systemFontOfSize:13];
    footer.textColor = UIColor.secondaryLabelColor;
    footer.numberOfLines = 0;
    footer.textAlignment = NSTextAlignmentCenter;
    footer.frame = CGRectMake(0, 0, self.tableView.bounds.size.width, 90);
    self.tableView.tableFooterView = footer;
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reloadActivity) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadActivity];
}

- (void)reloadActivity {
    self.items = BBRecentActivity(80);
    [self.tableView reloadData];
    [self.refreshControl endRefreshing];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return self.items.count ? @"Recent tasks" : @"No activity yet";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Activity"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Activity"];
    NSDictionary *item = self.items[indexPath.row];
    NSString *state = item[@"state"];
    NSString *status = [state isEqualToString:@"done"] ? @"Completed" :
        ([state isEqualToString:@"error"] ? @"Incomplete" :
         ([state isEqualToString:@"stopped"] ? @"Stopped" : @"Started"));
    NSString *symbol = [state isEqualToString:@"done"] ? @"checkmark.circle.fill" :
        ([state isEqualToString:@"error"] ? @"exclamationmark.circle.fill" :
         ([state isEqualToString:@"stopped"] ? @"stop.circle.fill" : @"clock.fill"));
    UIColor *tint = [state isEqualToString:@"done"] ? UIColor.systemGreenColor :
        ([state isEqualToString:@"error"] ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor);
    cell.imageView.image = [UIImage systemImageNamed:symbol];
    cell.imageView.tintColor = tint;
    cell.textLabel.text = item[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:[item[@"time"] doubleValue]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", status,
        [self.dateFormatter stringFromDate:date]];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end
