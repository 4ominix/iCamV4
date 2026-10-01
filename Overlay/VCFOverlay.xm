#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

// ── paths & notifications ───────────────────────
static NSString *const kConfigPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist";
static NSString *const kStatusPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist";
static NSString *const kServerPath  = @"/var/jb/var/mobile/Library/VCamFree/ServerStatus.plist";

static NSString *const kNotifConfigChanged = @"com.vcamfree.camera.config.changed";
static NSString *const kNotifStatusChanged = @"com.vcamfree.camera.status.changed";
static NSString *const kNotifServerChanged = @"com.vcamfree.server.status.changed";
static NSString *const kNotifFloatChanged  = @"com.vcamfree.floating.changed";

// ── floating overlay controller ─────────────────

@interface VCFFloatingController : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView   *panelView;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *serverLabel;
@property (nonatomic, assign) BOOL     panelVisible;
@property (nonatomic, assign) BOOL     cameraActive;
+ (instancetype)shared;
- (void)setup;
@end

@implementation VCFFloatingController

+ (instancetype)shared {
    static VCFFloatingController *inst;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (void)setup {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self _createWindow];
        [self _registerNotifications];
        [self _refreshStatus];
    });
}

#pragma mark - Window & UI

- (void)_createWindow {
    // find an active window scene
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) {
        // retry after a delay if SpringBoard hasn't finished launching
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ [self _createWindow]; });
        return;
    }

    self.overlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    self.overlayWindow.frame = CGRectMake(0, 0, 60, 60);
    self.overlayWindow.windowLevel = UIWindowLevelAlert + 100;
    self.overlayWindow.backgroundColor = [UIColor clearColor];
    self.overlayWindow.hidden = NO;
    self.overlayWindow.userInteractionEnabled = YES;
    self.overlayWindow.rootViewController = [[UIViewController alloc] init];

    // floating button
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(0, 0, 50, 50);
    self.floatingButton.center = CGPointMake(30, 30);
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:0.85];
    self.floatingButton.layer.cornerRadius = 25;
    self.floatingButton.layer.borderWidth = 2;
    self.floatingButton.layer.borderColor = [UIColor colorWithRed:0.3 green:0.8 blue:0.4 alpha:1].CGColor;
    self.floatingButton.clipsToBounds = YES;

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    UIImage *camIcon = [UIImage systemImageNamed:@"camera.fill" withConfiguration:symCfg];
    [self.floatingButton setImage:camIcon forState:UIControlStateNormal];
    self.floatingButton.tintColor = [UIColor whiteColor];

    [self.floatingButton addTarget:self action:@selector(_togglePanel)
                  forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handleDrag:)];
    [self.floatingButton addGestureRecognizer:pan];

    [self.overlayWindow.rootViewController.view addSubview:self.floatingButton];

    // panel (hidden by default)
    [self _createPanel];

    // position at right edge
    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    self.overlayWindow.frame = CGRectMake(screenW - 65, 200, 60, 60);
}

- (void)_createPanel {
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(-210, -20, 200, 160)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.hidden = YES;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, 176, 20)];
    title.text = @"VCamFree";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:15];
    [self.panelView addSubview:title];

    // camera toggle
    UIButton *toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    toggleBtn.frame = CGRectMake(12, 36, 176, 36);
    toggleBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.3 alpha:1];
    toggleBtn.layer.cornerRadius = 8;
    [toggleBtn setTitle:@"Toggle Camera" forState:UIControlStateNormal];
    [toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [toggleBtn addTarget:self action:@selector(_toggleCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:toggleBtn];

    // status label
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 80, 176, 18)];
    self.statusLabel.textColor = [UIColor lightGrayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.text = @"Camera: OFF";
    [self.panelView addSubview:self.statusLabel];

    // server label
    self.serverLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 100, 176, 18)];
    self.serverLabel.textColor = [UIColor lightGrayColor];
    self.serverLabel.font = [UIFont systemFontOfSize:11];
    self.serverLabel.text = @"RTMP: ...";
    [self.panelView addSubview:self.serverLabel];

    // open app button
    UIButton *appBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    appBtn.frame = CGRectMake(12, 124, 176, 28);
    [appBtn setTitle:@"Open VCamFree" forState:UIControlStateNormal];
    [appBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.7 blue:1 alpha:1] forState:UIControlStateNormal];
    appBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [appBtn addTarget:self action:@selector(_openApp) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:appBtn];

    [self.overlayWindow.rootViewController.view addSubview:self.panelView];
}

#pragma mark - Interactions

- (void)_togglePanel {
    self.panelVisible = !self.panelVisible;
    self.panelView.hidden = !self.panelVisible;
    if (self.panelVisible) {
        [self _refreshStatus];
        // expand window to fit panel
        CGRect f = self.overlayWindow.frame;
        self.overlayWindow.frame = CGRectMake(f.origin.x - 210, f.origin.y - 20, 270, 180);
        self.floatingButton.center = CGPointMake(240, 50);
    } else {
        CGRect f = self.overlayWindow.frame;
        self.overlayWindow.frame = CGRectMake(f.origin.x + 210, f.origin.y + 20, 60, 60);
        self.floatingButton.center = CGPointMake(30, 30);
    }
}

- (void)_handleDrag:(UIPanGestureRecognizer *)pan {
    if (self.panelVisible) return; // don't drag while panel open

    CGPoint translation = [pan translationInView:self.overlayWindow.rootViewController.view];
    CGRect f = self.overlayWindow.frame;
    f.origin.x += translation.x;
    f.origin.y += translation.y;

    // clamp to screen
    CGRect screen = [UIScreen mainScreen].bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, screen.size.width - f.size.width));
    f.origin.y = MAX(50, MIN(f.origin.y, screen.size.height - f.size.height - 30));

    self.overlayWindow.frame = f;
    [pan setTranslation:CGPointZero inView:self.overlayWindow.rootViewController.view];
}

- (void)_toggleCamera {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (existing) [cfg addEntriesFromDictionary:existing];

    BOOL current = [cfg[@"enabled"] boolValue];
    cfg[@"enabled"] = @(!current);
    [cfg writeToFile:kConfigPath atomically:YES];

    notify_post(kNotifConfigChanged.UTF8String);
    [self _refreshStatus];
}

- (void)_openApp {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"vcamfree://"]
                                       options:@{} completionHandler:nil];
    if (self.panelVisible) [self _togglePanel];
}

#pragma mark - Status

- (void)_refreshStatus {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:kStatusPath];
    BOOL active = [status[@"active"] boolValue];
    self.cameraActive = active;

    NSString *source = status[@"source"] ?: @"none";
    self.statusLabel.text = [NSString stringWithFormat:@"Camera: %@ [%@]",
                             active ? @"ON" : @"OFF", source];

    self.floatingButton.layer.borderColor = active
        ? [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1].CGColor
        : [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1].CGColor;

    NSDictionary *server = [NSDictionary dictionaryWithContentsOfFile:kServerPath];
    BOOL listening = [server[@"listening"] boolValue];
    int clients = [server[@"clients"] intValue];
    int port = [server[@"port"] intValue] ?: 1935;
    self.serverLabel.text = [NSString stringWithFormat:@"RTMP: %@ (port %d, %d client%s)",
                             listening ? @"UP" : @"DOWN", port,
                             clients, clients == 1 ? "" : "s"];
}

#pragma mark - Notifications

- (void)_registerNotifications {
    int token;
    notify_register_dispatch(kNotifStatusChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _refreshStatus];
        });
    notify_register_dispatch(kNotifServerChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _refreshStatus];
        });
}

@end

// ── constructor ─────────────────────────────────

%ctor {
    // only load in SpringBoard
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [[VCFFloatingController shared] setup];
    });
}
