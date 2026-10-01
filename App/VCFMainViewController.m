#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <spawn.h>
#import "VCFMediaStore.h"
#import "../Core/VCFSettings.h"
#import "../Core/VCFPaths.h"
#import "../Core/VCFFrameEngine.h"
#import "VCFAdjustments.h"

@interface VCFMainViewController : UIViewController
@end

@interface VCFMainViewController () <UITableViewDataSource, UITableViewDelegate,
                                      PHPickerViewControllerDelegate,
                                      UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) UISwitch *loopSwitch;
@property (nonatomic, strong) UISwitch *mirrorSwitch;
@property (nonatomic, strong) UISwitch *floatingSwitch;
@property (nonatomic, strong) UILabel *statusBanner;
@property (nonatomic, strong) UILabel *diagLabel;
@property (nonatomic, strong) UIImageView *previewView;
@property (nonatomic, strong) VCFAdjustments *adjustPanel;
@property (nonatomic, strong) VCFFrameEngine *previewEngine;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) NSDictionary *currentSettings;
@end

@implementation VCFMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VCamFree";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    NSString *base = VCFStorageDirectory(NULL);
    if (base) {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:base withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[base stringByAppendingPathComponent:@"Media"]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }

    [self _loadSettings];
    [self _setupUI];
    [self _registerNotifications];
    [self _startPreview];
}

- (void)_loadSettings {
    self.currentSettings = VCFReadSettings(NULL);
}

- (void)_saveEdit:(void (^)(NSMutableDictionary *))edit {
    VCFUpdateSettings(edit, NULL);
    [self _loadSettings];
    [self _updateStatusBanner];
}

#pragma mark - UI

- (void)_setupUI {
    self.statusBanner = [[UILabel alloc] init];
    self.statusBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBanner.textAlignment = NSTextAlignmentCenter;
    self.statusBanner.font = [UIFont boldSystemFontOfSize:14];
    self.statusBanner.textColor = [UIColor whiteColor];
    self.statusBanner.layer.cornerRadius = 8;
    self.statusBanner.clipsToBounds = YES;
    self.statusBanner.userInteractionEnabled = YES;
    [self.statusBanner addGestureRecognizer:
     [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_bannerTapped)]];
    [self.view addSubview:self.statusBanner];

    self.previewView = [[UIImageView alloc] init];
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    self.previewView.contentMode = UIViewContentModeScaleAspectFit;
    self.previewView.backgroundColor = [UIColor blackColor];
    self.previewView.layer.cornerRadius = 8;
    self.previewView.clipsToBounds = YES;
    [self.view addSubview:self.previewView];

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusBanner.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.statusBanner.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.statusBanner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.statusBanner.heightAnchor constraintEqualToConstant:36],

        [self.previewView.topAnchor constraintEqualToAnchor:self.statusBanner.bottomAnchor constant:8],
        [self.previewView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.previewView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.previewView.heightAnchor constraintEqualToConstant:200],

        [self.tableView.topAnchor constraintEqualToAnchor:self.previewView.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self _updateStatusBanner];
}

- (void)_updateStatusBanner {
    NSDictionary *s = self.currentSettings;
    BOOL enabled = [s[@"Enabled"] boolValue];
    NSString *media = s[@"Media"];
    if (enabled && media.length) {
        self.statusBanner.text = [NSString stringWithFormat:@"  CAMERA ACTIVE — %@  ", media];
        self.statusBanner.backgroundColor = [UIColor colorWithRed:0.15 green:0.65 blue:0.3 alpha:1];
    } else if (enabled) {
        self.statusBanner.text = @"  CAMERA ON — No media selected  ";
        self.statusBanner.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:1];
    } else {
        self.statusBanner.text = @"  CAMERA OFF — Tap to toggle  ";
        self.statusBanner.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1];
    }
}

- (void)_startPreview {
    self.previewEngine = [[VCFFrameEngine alloc] initForPreview:YES];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_renderPreview)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(10, 30, 30);
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)_renderPreview {
    CVPixelBufferRef frame = [self.previewEngine copyFrameForWidth:360 height:640
                                                            format:kCVPixelFormatType_32BGRA];
    if (!frame) return;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:frame];
    CVPixelBufferRelease(frame);
    if (ci) self.previewView.image = [UIImage imageWithCIImage:ci];
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 6; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 4;
        case 1: return [VCFMediaStore shared].items.count + 1;
        case 2: return 2;
        case 3: return 2;
        case 4: return 1;
        case 5: return 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Controls";
        case 1: return @"Media Library";
        case 2: return @"Fill Mode";
        case 3: return @"OBS / RTMP";
        case 4: return @"Diagnostics";
        case 5: return @"Maintenance";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *reuseID = [NSString stringWithFormat:@"s%ld_r%ld", (long)indexPath.section, (long)indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuseID];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseID];

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.imageView.image = nil;

    NSDictionary *s = self.currentSettings;

    switch (indexPath.section) {
        case 0: {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Enable Virtual Camera";
                cell.imageView.image = [UIImage systemImageNamed:@"camera.fill"];
                cell.imageView.tintColor = [s[@"Enabled"] boolValue] ?
                    [UIColor systemGreenColor] : [UIColor systemGrayColor];
                if (!self.masterSwitch) {
                    self.masterSwitch = [[UISwitch alloc] init];
                    [self.masterSwitch addTarget:self action:@selector(_masterToggle:)
                                forControlEvents:UIControlEventValueChanged];
                }
                self.masterSwitch.on = [s[@"Enabled"] boolValue];
                cell.accessoryView = self.masterSwitch;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Loop Video";
                cell.imageView.image = [UIImage systemImageNamed:@"repeat"];
                if (!self.loopSwitch) {
                    self.loopSwitch = [[UISwitch alloc] init];
                    [self.loopSwitch addTarget:self action:@selector(_loopToggle:)
                              forControlEvents:UIControlEventValueChanged];
                }
                self.loopSwitch.on = [s[@"Loop"] boolValue];
                cell.accessoryView = self.loopSwitch;
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"Mirror";
                cell.imageView.image = [UIImage systemImageNamed:@"arrow.left.and.right"];
                if (!self.mirrorSwitch) {
                    self.mirrorSwitch = [[UISwitch alloc] init];
                    [self.mirrorSwitch addTarget:self action:@selector(_mirrorToggle:)
                                forControlEvents:UIControlEventValueChanged];
                }
                self.mirrorSwitch.on = [s[@"Mirror"] boolValue];
                cell.accessoryView = self.mirrorSwitch;
            } else {
                cell.textLabel.text = @"Floating Controls";
                cell.imageView.image = [UIImage systemImageNamed:@"pip"];
                if (!self.floatingSwitch) {
                    self.floatingSwitch = [[UISwitch alloc] init];
                    [self.floatingSwitch addTarget:self action:@selector(_floatingToggle:)
                                  forControlEvents:UIControlEventValueChanged];
                }
                self.floatingSwitch.on = [s[@"Floating"] boolValue];
                cell.accessoryView = self.floatingSwitch;
            }
            break;
        }
        case 1: {
            NSArray<VCFMediaItem *> *items = [VCFMediaStore shared].items;
            if (indexPath.row < (NSInteger)items.count) {
                VCFMediaItem *item = items[indexPath.row];
                cell.textLabel.text = item.filename;
                NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:(long long)item.fileSize
                                                                  countStyle:NSByteCountFormatterCountStyleFile];
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — %@",
                    item.type == VCFMediaTypeVideo ? @"Video" : @"Image", sizeStr];
                cell.imageView.image = [UIImage systemImageNamed:
                    item.type == VCFMediaTypeVideo ? @"film" : @"photo"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                BOOL selected = [s[@"Media"] isEqualToString:item.filename];
                cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark
                                              : UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Import Media...";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
                cell.imageView.tintColor = [UIColor systemBlueColor];
            }
            break;
        }
        case 2: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Fit";
                cell.detailTextLabel.text = @"Show full image with black bars";
                cell.accessoryType = ![s[@"Fill"] boolValue] ? UITableViewCellAccessoryCheckmark
                                                              : UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Fill";
                cell.detailTextLabel.text = @"Fill frame, crop edges";
                cell.accessoryType = [s[@"Fill"] boolValue] ? UITableViewCellAccessoryCheckmark
                                                             : UITableViewCellAccessoryNone;
            }
            break;
        }
        case 3: {
            if (indexPath.row == 0) {
                NSString *base = VCFStorageDirectory(NULL);
                NSString *serverPath = [base stringByAppendingPathComponent:@"ServerStatus.plist"];
                NSDictionary *server = [NSDictionary dictionaryWithContentsOfFile:serverPath];
                BOOL listening = [server[@"listening"] boolValue];
                int clients = [server[@"clients"] intValue];
                int port = [server[@"port"] intValue] ?: 1935;
                cell.textLabel.text = @"RTMP Server";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — :%d, %d client%s",
                    listening ? @"Running" : @"Stopped", port, clients, clients == 1 ? "" : "s"];
                cell.imageView.image = [UIImage systemImageNamed:
                    listening ? @"checkmark.circle.fill" : @"xmark.circle"];
                cell.imageView.tintColor = listening ? [UIColor systemGreenColor] : [UIColor systemRedColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                NSString *localIP = [self _localIPAddress];
                cell.textLabel.text = @"Copy OBS URL";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"rtmp://%@:1935/live",
                                             localIP ?: @"<ip>"];
                cell.imageView.image = [UIImage systemImageNamed:@"doc.on.doc"];
                cell.imageView.tintColor = [UIColor systemTealColor];
            }
            break;
        }
        case 4: {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.text = @"Hook Status";
            cell.textLabel.textColor = [UIColor systemGrayColor];
            NSString *base = VCFStorageDirectory(NULL);
            NSMutableString *diag = [NSMutableString new];
            for (NSString *proc in @[@"cameracaptured", @"mediaserverd"]) {
                NSString *pattern = [NSString stringWithFormat:@"Status.%@.", proc];
                NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:nil];
                for (NSString *f in files) {
                    if (![f hasPrefix:pattern]) continue;
                    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                                       [base stringByAppendingPathComponent:f]];
                    if (!d) continue;
                    [diag appendFormat:@"%@: %@ hooks=%@ replaced=%@\n",
                     d[@"Host"] ?: proc, d[@"State"] ?: @"?",
                     d[@"Hooks"] ?: @"0", d[@"Replaced"] ?: @"0"];
                }
            }
            cell.detailTextLabel.text = diag.length ? diag : @"No hook status files found";
            cell.detailTextLabel.numberOfLines = 0;
            cell.imageView.image = [UIImage systemImageNamed:@"info.circle"];
            cell.imageView.tintColor = [UIColor systemGrayColor];
            break;
        }
        case 5: {
            cell.textLabel.text = @"Respring";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise"];
            cell.imageView.tintColor = [UIColor systemRedColor];
            break;
        }
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 1: {
            NSArray<VCFMediaItem *> *items = [VCFMediaStore shared].items;
            if (indexPath.row < (NSInteger)items.count) {
                VCFMediaItem *item = items[indexPath.row];
                NSString *kind = item.type == VCFMediaTypeVideo ? @"video" : @"image";
                [self _saveEdit:^(NSMutableDictionary *s) {
                    s[@"Media"] = item.filename;
                    s[@"Kind"] = kind;
                }];
                [tableView reloadData];
            } else {
                [self _showImportPicker];
            }
            break;
        }
        case 2: {
            [self _saveEdit:^(NSMutableDictionary *s) {
                s[@"Fill"] = @(indexPath.row == 1);
            }];
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:2]
                     withRowAnimation:UITableViewRowAnimationNone];
            break;
        }
        case 3: {
            if (indexPath.row == 1) {
                NSString *localIP = [self _localIPAddress];
                NSString *url = [NSString stringWithFormat:@"rtmp://%@:1935/live", localIP ?: @"<ip>"];
                [UIPasteboard generalPasteboard].string = url;
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Copied"
                    message:url preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:a animated:YES completion:nil];
            }
            break;
        }
        case 5: {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Respring?"
                message:@"This will restart SpringBoard to reload hooks."
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                    pid_t pid;
                    const char *argv[] = {"/var/jb/usr/bin/sbreload", NULL};
                    posix_spawn(&pid, argv[0], NULL, NULL, (char **)argv, NULL);
                }]];
            [self presentViewController:a animated:YES completion:nil];
            break;
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 1 && indexPath.row < (NSInteger)[VCFMediaStore shared].items.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (style != UITableViewCellEditingStyleDelete) return;
    NSArray<VCFMediaItem *> *items = [VCFMediaStore shared].items;
    if (indexPath.row >= (NSInteger)items.count) return;

    VCFMediaItem *item = items[indexPath.row];
    NSString *currentMedia = self.currentSettings[@"Media"];
    if ([currentMedia isEqualToString:item.filename]) {
        [self _saveEdit:^(NSMutableDictionary *s) { s[@"Media"] = @""; }];
    }
    [[VCFMediaStore shared] deleteItem:item];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:1]
             withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Toggles

- (void)_bannerTapped {
    BOOL current = [self.currentSettings[@"Enabled"] boolValue];
    [self _saveEdit:^(NSMutableDictionary *s) { s[@"Enabled"] = @(!current); }];
    self.masterSwitch.on = !current;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)_masterToggle:(UISwitch *)sw {
    [self _saveEdit:^(NSMutableDictionary *s) { s[@"Enabled"] = @(sw.on); }];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:0]
                  withRowAnimation:UITableViewRowAnimationNone];
}

- (void)_loopToggle:(UISwitch *)sw {
    [self _saveEdit:^(NSMutableDictionary *s) { s[@"Loop"] = @(sw.on); }];
}

- (void)_mirrorToggle:(UISwitch *)sw {
    [self _saveEdit:^(NSMutableDictionary *s) { s[@"Mirror"] = @(sw.on); }];
}

- (void)_floatingToggle:(UISwitch *)sw {
    [self _saveEdit:^(NSMutableDictionary *s) { s[@"Floating"] = @(sw.on); }];
}

#pragma mark - Import

- (void)_showImportPicker {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Import Media"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Photo Library"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
            cfg.selectionLimit = 1;
            cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[
                [PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]
            ]];
            PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
            picker.delegate = self;
            [self presentViewController:picker animated:YES completion:nil];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Files"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UIDocumentPickerViewController *dp =
                [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:
                    @[[UTType typeWithIdentifier:@"public.image"],
                      [UTType typeWithIdentifier:@"public.movie"]]];
            dp.delegate = self;
            dp.allowsMultipleSelection = NO;
            [self presentViewController:dp animated:YES completion:nil];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    NSItemProvider *provider = results[0].itemProvider;

    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
            completionHandler:^(NSURL *url, NSError *err) {
                if (!url) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    VCFMediaItem *item = [[VCFMediaStore shared] importFileAtURL:url];
                    if (item) {
                        [self _saveEdit:^(NSMutableDictionary *s) {
                            s[@"Media"] = item.filename; s[@"Kind"] = @"video";
                        }];
                    }
                    [self.tableView reloadData];
                });
            }];
    } else if ([provider canLoadObjectOfClass:[UIImage class]]) {
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
            if (!img) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *name = [NSString stringWithFormat:@"import_%ld.jpg",
                                  (long)[[NSDate date] timeIntervalSince1970]];
                VCFMediaItem *item = [[VCFMediaStore shared] importImage:img withName:name];
                if (item) {
                    [self _saveEdit:^(NSMutableDictionary *s) {
                        s[@"Media"] = item.filename; s[@"Kind"] = @"image";
                    }];
                }
                [self.tableView reloadData];
            });
        }];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    VCFMediaItem *item = [[VCFMediaStore shared] importFileAtURL:urls[0]];
    if (item) {
        NSString *kind = item.type == VCFMediaTypeVideo ? @"video" : @"image";
        [self _saveEdit:^(NSMutableDictionary *s) { s[@"Media"] = item.filename; s[@"Kind"] = kind; }];
    }
    [self.tableView reloadData];
}

#pragma mark - Notifications

- (void)_registerNotifications {
    int token;
    notify_register_dispatch(VCFSettingsNotification.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _loadSettings];
            [self _updateStatusBanner];
            [self.tableView reloadData];
        });
}

#pragma mark - Helpers

- (NSString *)_localIPAddress {
    struct ifaddrs *interfaces = NULL;
    NSString *address = nil;
    if (getifaddrs(&interfaces) == 0) {
        struct ifaddrs *temp = interfaces;
        while (temp) {
            if (temp->ifa_addr && temp->ifa_addr->sa_family == AF_INET) {
                NSString *ifname = [NSString stringWithUTF8String:temp->ifa_name];
                if ([ifname isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:
                        inet_ntoa(((struct sockaddr_in *)temp->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp = temp->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return address;
}

- (void)dealloc {
    [self.displayLink invalidate];
}

@end
