#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <notify.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import "VCFMediaStore.h"

// ── paths & notifications ───────────────────────
static NSString *const kConfigPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist";
static NSString *const kStatusPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist";
static NSString *const kServerPath  = @"/var/jb/var/mobile/Library/VCamFree/ServerStatus.plist";
static NSString *const kStreamDir   = @"/var/jb/var/mobile/Library/VCamFree/Streams";

static NSString *const kNotifConfigChanged = @"com.vcamfree.camera.config.changed";
static NSString *const kNotifStatusChanged = @"com.vcamfree.camera.status.changed";
static NSString *const kNotifServerChanged = @"com.vcamfree.server.status.changed";

// ── source type enum ────────────────────────────
typedef NS_ENUM(NSInteger, VCFSourceMode) {
    VCFSourceModeNone = 0,
    VCFSourceModeImage,
    VCFSourceModeVideo,
    VCFSourceModeStream
};

// ── main view controller ────────────────────────

@interface VCFMainViewController : UIViewController
@end

@interface VCFMainViewController () <UITableViewDataSource, UITableViewDelegate,
                                      PHPickerViewControllerDelegate,
                                      UIDocumentPickerDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch    *masterSwitch;
@property (nonatomic, strong) UILabel     *statusBanner;
@property (nonatomic, strong) UILabel     *serverStatusLabel;
@property (nonatomic, strong) UILabel     *obsURLLabel;

@property (nonatomic, assign) BOOL          cameraEnabled;
@property (nonatomic, assign) VCFSourceMode sourceMode;
@property (nonatomic, copy)   NSString     *selectedMedia;
@property (nonatomic, assign) BOOL          serverListening;
@property (nonatomic, assign) int           serverPort;
@property (nonatomic, assign) int           serverClients;
@end

@implementation VCFMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"VCamFree";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    [self _loadConfig];
    [self _setupUI];
    [self _registerNotifications];
    [self _refreshServerStatus];
}

#pragma mark - UI Setup

- (void)_setupUI {
    // status banner at top
    self.statusBanner = [[UILabel alloc] init];
    self.statusBanner.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusBanner.textAlignment = NSTextAlignmentCenter;
    self.statusBanner.font = [UIFont boldSystemFontOfSize:14];
    self.statusBanner.textColor = [UIColor whiteColor];
    self.statusBanner.layer.cornerRadius = 8;
    self.statusBanner.clipsToBounds = YES;
    [self.view addSubview:self.statusBanner];

    // table view
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

        [self.tableView.topAnchor constraintEqualToAnchor:self.statusBanner.bottomAnchor constant:8],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self _updateStatusBanner];
}

- (void)_updateStatusBanner {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:kStatusPath];
    BOOL active = [status[@"active"] boolValue];

    if (active) {
        self.statusBanner.text = [NSString stringWithFormat:@"CAMERA ACTIVE — %@",
                                  [status[@"source"] uppercaseString] ?: @""];
        self.statusBanner.backgroundColor = [UIColor colorWithRed:0.15 green:0.65 blue:0.3 alpha:1];
    } else {
        self.statusBanner.text = @"CAMERA OFF";
        self.statusBanner.backgroundColor = [UIColor colorWithRed:0.3 green:0.3 blue:0.35 alpha:1];
    }
}

#pragma mark - Config

- (void)_loadConfig {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    self.cameraEnabled = [cfg[@"enabled"] boolValue];
    self.selectedMedia = cfg[@"media_path"];

    NSString *src = cfg[@"source_type"];
    if ([src isEqualToString:@"image"])       self.sourceMode = VCFSourceModeImage;
    else if ([src isEqualToString:@"video"])  self.sourceMode = VCFSourceModeVideo;
    else if ([src isEqualToString:@"stream"]) self.sourceMode = VCFSourceModeStream;
    else self.sourceMode = VCFSourceModeNone;
}

- (void)_saveConfig {
    NSString *srcStr;
    switch (self.sourceMode) {
        case VCFSourceModeImage:  srcStr = @"image"; break;
        case VCFSourceModeVideo:  srcStr = @"video"; break;
        case VCFSourceModeStream: srcStr = @"stream"; break;
        default: srcStr = @"none"; break;
    }

    NSDictionary *cfg = @{
        @"enabled": @(self.cameraEnabled),
        @"source_type": srcStr,
        @"media_path": self.selectedMedia ?: @""
    };
    [cfg writeToFile:kConfigPath atomically:YES];
    notify_post(kNotifConfigChanged.UTF8String);
}

- (void)_refreshServerStatus {
    NSDictionary *server = [NSDictionary dictionaryWithContentsOfFile:kServerPath];
    self.serverListening = [server[@"listening"] boolValue];
    self.serverPort = [server[@"port"] intValue] ?: 1935;
    self.serverClients = [server[@"clients"] intValue];
}

#pragma mark - TableView

// sections: 0=master switch, 1=source mode, 2=media library, 3=OBS/RTMP, 4=actions
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 1; // master switch
        case 1: return 3; // source modes: image, video, stream
        case 2: return [VCFMediaStore shared].items.count + 1; // media + import button
        case 3: return 2; // RTMP status + OBS URL
        case 4: return 1; // clear streams
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Virtual Camera";
        case 1: return @"Source Mode";
        case 2: return @"Media Library";
        case 3: return @"OBS / RTMP Stream";
        case 4: return @"Maintenance";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
    }

    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    switch (indexPath.section) {
        case 0: {
            cell.textLabel.text = @"Enable Virtual Camera";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            if (!self.masterSwitch) {
                self.masterSwitch = [[UISwitch alloc] init];
                [self.masterSwitch addTarget:self action:@selector(_masterSwitchChanged:)
                            forControlEvents:UIControlEventValueChanged];
            }
            self.masterSwitch.on = self.cameraEnabled;
            cell.accessoryView = self.masterSwitch;
            break;
        }
        case 1: {
            NSArray *titles = @[@"Image", @"Video File", @"RTMP Stream (OBS)"];
            NSArray *subtitles = @[@"Static image as camera", @"Loop a video file",
                                   @"Live stream from OBS Studio"];
            NSArray *icons = @[@"photo", @"film", @"antenna.radiowaves.left.and.right"];
            cell.textLabel.text = titles[indexPath.row];
            cell.detailTextLabel.text = subtitles[indexPath.row];
            cell.imageView.image = [UIImage systemImageNamed:icons[indexPath.row]];
            cell.imageView.tintColor = [UIColor systemBlueColor];

            VCFSourceMode mode = (VCFSourceMode)(indexPath.row + 1);
            cell.accessoryType = (self.sourceMode == mode)
                ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            break;
        }
        case 2: {
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

                BOOL selected = [self.selectedMedia isEqualToString:item.filename];
                cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark
                                              : UITableViewCellAccessoryNone;
            } else {
                cell.textLabel.text = @"Import Media...";
                cell.textLabel.textColor = [UIColor systemBlueColor];
                cell.detailTextLabel.text = nil;
                cell.imageView.image = [UIImage systemImageNamed:@"plus.circle.fill"];
                cell.imageView.tintColor = [UIColor systemBlueColor];
            }
            break;
        }
        case 3: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"RTMP Server";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ — port %d, %d client%s",
                    self.serverListening ? @"Running" : @"Stopped",
                    self.serverPort, self.serverClients,
                    self.serverClients == 1 ? "" : "s"];
                cell.imageView.image = [UIImage systemImageNamed:
                    self.serverListening ? @"checkmark.circle.fill" : @"xmark.circle"];
                cell.imageView.tintColor = self.serverListening
                    ? [UIColor systemGreenColor] : [UIColor systemRedColor];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
            } else {
                NSString *localIP = [self _localIPAddress];
                NSString *obsURL = [NSString stringWithFormat:@"rtmp://%@:%d/live",
                                    localIP ?: @"<device-ip>", self.serverPort];
                cell.textLabel.text = @"OBS URL";
                cell.detailTextLabel.text = obsURL;
                cell.detailTextLabel.numberOfLines = 0;
                cell.imageView.image = [UIImage systemImageNamed:@"doc.on.doc"];
                cell.imageView.tintColor = [UIColor systemTealColor];
            }
            break;
        }
        case 4: {
            cell.textLabel.text = @"Clear Stream Cache";
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.imageView.image = [UIImage systemImageNamed:@"trash"];
            cell.imageView.tintColor = [UIColor systemRedColor];
            break;
        }
    }
    return cell;
}

#pragma mark - TableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    switch (indexPath.section) {
        case 1: {
            self.sourceMode = (VCFSourceMode)(indexPath.row + 1);
            [self _saveConfig];
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
            break;
        }
        case 2: {
            NSArray<VCFMediaItem *> *items = [VCFMediaStore shared].items;
            if (indexPath.row < (NSInteger)items.count) {
                VCFMediaItem *item = items[indexPath.row];
                self.selectedMedia = item.filename;
                self.sourceMode = (item.type == VCFMediaTypeVideo) ? VCFSourceModeVideo : VCFSourceModeImage;
                [self _saveConfig];
                [tableView reloadData];
            } else {
                [self _showImportPicker];
            }
            break;
        }
        case 3: {
            if (indexPath.row == 1) {
                NSString *localIP = [self _localIPAddress];
                NSString *obsURL = [NSString stringWithFormat:@"rtmp://%@:%d/live",
                                    localIP ?: @"<device-ip>", self.serverPort];
                [UIPasteboard generalPasteboard].string = obsURL;

                UIAlertController *alert = [UIAlertController
                    alertControllerWithTitle:@"Copied"
                    message:[NSString stringWithFormat:@"OBS URL copied:\n%@", obsURL]
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                    style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:alert animated:YES completion:nil];
            }
            break;
        }
        case 4: {
            [self _clearStreamCache];
            break;
        }
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.section == 2 && indexPath.row < (NSInteger)[VCFMediaStore shared].items.count;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
    forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSArray<VCFMediaItem *> *items = [VCFMediaStore shared].items;
    if (indexPath.row >= (NSInteger)items.count) return;

    VCFMediaItem *item = items[indexPath.row];
    if ([self.selectedMedia isEqualToString:item.filename]) {
        self.selectedMedia = nil;
    }
    [[VCFMediaStore shared] deleteItem:item];
    [self _saveConfig];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationAutomatic];
}

#pragma mark - Actions

- (void)_masterSwitchChanged:(UISwitch *)sw {
    self.cameraEnabled = sw.on;
    [self _saveConfig];
}

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

- (void)_clearStreamCache {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear Streams?"
        message:@"Delete all cached stream files."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Delete"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kStreamDir error:nil];
            for (NSString *f in files) {
                [[NSFileManager defaultManager] removeItemAtPath:
                    [kStreamDir stringByAppendingPathComponent:f] error:nil];
            }
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;

    PHPickerResult *result = results[0];
    NSItemProvider *provider = result.itemProvider;

    if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadFileRepresentationForTypeIdentifier:@"public.movie"
            completionHandler:^(NSURL *url, NSError *err) {
                if (!url) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    VCFMediaItem *item = [[VCFMediaStore shared] importFileAtURL:url];
                    if (item) {
                        self.selectedMedia = item.filename;
                        self.sourceMode = VCFSourceModeVideo;
                        [self _saveConfig];
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
                    self.selectedMedia = item.filename;
                    self.sourceMode = VCFSourceModeImage;
                    [self _saveConfig];
                }
                [self.tableView reloadData];
            });
        }];
    }
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    VCFMediaItem *item = [[VCFMediaStore shared] importFileAtURL:urls[0]];
    if (item) {
        self.selectedMedia = item.filename;
        self.sourceMode = (item.type == VCFMediaTypeVideo) ? VCFSourceModeVideo : VCFSourceModeImage;
        [self _saveConfig];
    }
    [self.tableView reloadData];
}

#pragma mark - Notifications

- (void)_registerNotifications {
    int token;
    notify_register_dispatch(kNotifStatusChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _updateStatusBanner];
        });
    notify_register_dispatch(kNotifServerChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _refreshServerStatus];
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3]
                          withRowAnimation:UITableViewRowAnimationNone];
        });
}

#pragma mark - Helpers

- (NSString *)_localIPAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp = NULL;
    NSString *address = nil;

    if (getifaddrs(&interfaces) == 0) {
        temp = interfaces;
        while (temp != NULL) {
            if (temp->ifa_addr->sa_family == AF_INET) {
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

@end
