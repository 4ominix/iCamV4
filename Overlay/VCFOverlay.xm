#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

static NSString *const kConfigPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist";
static NSString *const kStatusPath  = @"/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist";
static NSString *const kServerPath  = @"/var/jb/var/mobile/Library/VCamFree/ServerStatus.plist";

static NSString *const kNotifConfigChanged = @"com.vcamfree.camera.config.changed";
static NSString *const kNotifStatusChanged = @"com.vcamfree.camera.status.changed";
static NSString *const kNotifServerChanged = @"com.vcamfree.server.status.changed";

@interface VCFFloatingController : NSObject
@property (nonatomic, strong) UIWindow *overlayWindow;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView   *panelView;
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UILabel  *serverLabel;
@property (nonatomic, assign) BOOL     panelVisible;
@property (nonatomic, assign) BOOL     cameraActive;

@property (nonatomic, strong) UISlider *sliderX;
@property (nonatomic, strong) UISlider *sliderY;
@property (nonatomic, strong) UISlider *sliderZoom;
@property (nonatomic, strong) UISlider *sliderBright;
@property (nonatomic, strong) UISlider *sliderSat;

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
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            scene = (UIWindowScene *)s;
            break;
        }
    }
    if (!scene) {
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

    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(0, 0, 50, 50);
    self.floatingButton.center = CGPointMake(30, 30);
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.9];
    self.floatingButton.layer.cornerRadius = 25;
    self.floatingButton.layer.borderWidth = 2.5;
    self.floatingButton.layer.borderColor = [UIColor colorWithRed:0.3 green:0.8 blue:0.4 alpha:1].CGColor;
    self.floatingButton.clipsToBounds = YES;

    UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
    [self.floatingButton setImage:[UIImage systemImageNamed:@"camera.fill" withConfiguration:symCfg] forState:UIControlStateNormal];
    self.floatingButton.tintColor = [UIColor whiteColor];

    [self.floatingButton addTarget:self action:@selector(_togglePanel)
                  forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_handleDrag:)];
    [self.floatingButton addGestureRecognizer:pan];
    [self.overlayWindow.rootViewController.view addSubview:self.floatingButton];

    [self _createPanel];

    CGFloat screenW = [UIScreen mainScreen].bounds.size.width;
    self.overlayWindow.frame = CGRectMake(screenW - 65, 200, 60, 60);
}

- (UISlider *)_makeSlider:(float)min max:(float)max val:(float)val action:(SEL)action {
    UISlider *s = [[UISlider alloc] init];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = val;
    s.minimumTrackTintColor = [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1];
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UILabel *)_makeLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    l.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    return l;
}

- (void)_createPanel {
    CGFloat pw = 240, ph = 370;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(-(pw + 10), -(ph/2 - 25), pw, ph)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.12 alpha:0.96];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.hidden = YES;

    CGFloat y = 10, mx = 12, cw = pw - 2 * mx;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(mx, y, cw, 22)];
    title.text = @"VCamFree";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panelView addSubview:title];
    y += 28;

    // toggle
    UIButton *toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    toggleBtn.frame = CGRectMake(mx, y, cw, 34);
    toggleBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:0.3 alpha:1];
    toggleBtn.layer.cornerRadius = 8;
    [toggleBtn setTitle:@"Toggle Camera" forState:UIControlStateNormal];
    [toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [toggleBtn addTarget:self action:@selector(_toggleCamera) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:toggleBtn];
    y += 40;

    // status
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(mx, y, cw, 16)];
    self.statusLabel.textColor = [UIColor lightGrayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.text = @"Camera: OFF";
    [self.panelView addSubview:self.statusLabel];
    y += 16;

    self.serverLabel = [[UILabel alloc] initWithFrame:CGRectMake(mx, y, cw, 16)];
    self.serverLabel.textColor = [UIColor lightGrayColor];
    self.serverLabel.font = [UIFont systemFontOfSize:10];
    self.serverLabel.text = @"RTMP: ...";
    [self.panelView addSubview:self.serverLabel];
    y += 22;

    // separator
    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(mx, y, cw, 1)];
    sep1.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    [self.panelView addSubview:sep1];
    y += 8;

    // -- POSITION --
    UILabel *posTitle = [self _makeLabel:@"POSITION"];
    posTitle.frame = CGRectMake(mx, y, cw, 14);
    posTitle.font = [UIFont boldSystemFontOfSize:10];
    [self.panelView addSubview:posTitle];
    y += 16;

    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];

    UILabel *xLbl = [self _makeLabel:@"X Offset"];
    xLbl.frame = CGRectMake(mx, y, 50, 14);
    [self.panelView addSubview:xLbl];
    self.sliderX = [self _makeSlider:-0.5f max:0.5f val:[cfg[@"offset_x"] floatValue] action:@selector(_sliderChanged)];
    self.sliderX.frame = CGRectMake(mx + 52, y - 2, cw - 52, 18);
    [self.panelView addSubview:self.sliderX];
    y += 22;

    UILabel *yLbl = [self _makeLabel:@"Y Offset"];
    yLbl.frame = CGRectMake(mx, y, 50, 14);
    [self.panelView addSubview:yLbl];
    self.sliderY = [self _makeSlider:-0.5f max:0.5f val:[cfg[@"offset_y"] floatValue] action:@selector(_sliderChanged)];
    self.sliderY.frame = CGRectMake(mx + 52, y - 2, cw - 52, 18);
    [self.panelView addSubview:self.sliderY];
    y += 22;

    UILabel *zLbl = [self _makeLabel:@"Zoom"];
    zLbl.frame = CGRectMake(mx, y, 50, 14);
    [self.panelView addSubview:zLbl];
    self.sliderZoom = [self _makeSlider:0.5f max:3.0f val:[cfg[@"scale"] floatValue] ?: 1.0f action:@selector(_sliderChanged)];
    self.sliderZoom.frame = CGRectMake(mx + 52, y - 2, cw - 52, 18);
    [self.panelView addSubview:self.sliderZoom];
    y += 26;

    // separator
    UIView *sep2 = [[UIView alloc] initWithFrame:CGRectMake(mx, y, cw, 1)];
    sep2.backgroundColor = [UIColor colorWithWhite:0.25 alpha:1];
    [self.panelView addSubview:sep2];
    y += 8;

    // -- COLOR SYNC --
    UILabel *colTitle = [self _makeLabel:@"COLOR SYNC"];
    colTitle.frame = CGRectMake(mx, y, cw, 14);
    colTitle.font = [UIFont boldSystemFontOfSize:10];
    [self.panelView addSubview:colTitle];
    y += 16;

    UILabel *bLbl = [self _makeLabel:@"Bright"];
    bLbl.frame = CGRectMake(mx, y, 50, 14);
    [self.panelView addSubview:bLbl];
    self.sliderBright = [self _makeSlider:-0.5f max:0.5f val:[cfg[@"color_brightness"] floatValue] action:@selector(_sliderChanged)];
    self.sliderBright.frame = CGRectMake(mx + 52, y - 2, cw - 52, 18);
    [self.panelView addSubview:self.sliderBright];
    y += 22;

    UILabel *sLbl = [self _makeLabel:@"Saturat"];
    sLbl.frame = CGRectMake(mx, y, 50, 14);
    [self.panelView addSubview:sLbl];
    self.sliderSat = [self _makeSlider:0.0f max:2.0f val:[cfg[@"color_saturation"] floatValue] ?: 1.0f action:@selector(_sliderChanged)];
    self.sliderSat.frame = CGRectMake(mx + 52, y - 2, cw - 52, 18);
    [self.panelView addSubview:self.sliderSat];
    y += 26;

    // reset button
    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    resetBtn.frame = CGRectMake(mx, y, cw / 2 - 4, 28);
    [resetBtn setTitle:@"Reset" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    resetBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    resetBtn.layer.cornerRadius = 6;
    [resetBtn addTarget:self action:@selector(_resetSliders) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:resetBtn];

    // open app button
    UIButton *appBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    appBtn.frame = CGRectMake(mx + cw / 2 + 4, y, cw / 2 - 4, 28);
    [appBtn setTitle:@"Open App" forState:UIControlStateNormal];
    [appBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.7 blue:1 alpha:1] forState:UIControlStateNormal];
    appBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    appBtn.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1];
    appBtn.layer.cornerRadius = 6;
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
        CGRect f = self.overlayWindow.frame;
        self.overlayWindow.frame = CGRectMake(f.origin.x - 250, f.origin.y - 160, 310, 400);
        self.floatingButton.center = CGPointMake(280, 190);
    } else {
        CGRect f = self.overlayWindow.frame;
        self.overlayWindow.frame = CGRectMake(f.origin.x + 250, f.origin.y + 160, 60, 60);
        self.floatingButton.center = CGPointMake(30, 30);
    }
}

- (void)_handleDrag:(UIPanGestureRecognizer *)pan {
    if (self.panelVisible) return;
    CGPoint translation = [pan translationInView:self.overlayWindow.rootViewController.view];
    CGRect f = self.overlayWindow.frame;
    f.origin.x += translation.x;
    f.origin.y += translation.y;
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ [self _refreshStatus]; });
}

- (void)_sliderChanged {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    NSDictionary *existing = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (existing) [cfg addEntriesFromDictionary:existing];

    cfg[@"offset_x"] = @(self.sliderX.value);
    cfg[@"offset_y"] = @(self.sliderY.value);
    cfg[@"scale"] = @(self.sliderZoom.value);
    cfg[@"color_brightness"] = @(self.sliderBright.value);
    cfg[@"color_saturation"] = @(self.sliderSat.value);

    [cfg writeToFile:kConfigPath atomically:YES];
    notify_post(kNotifConfigChanged.UTF8String);
}

- (void)_resetSliders {
    self.sliderX.value = 0;
    self.sliderY.value = 0;
    self.sliderZoom.value = 1.0f;
    self.sliderBright.value = 0;
    self.sliderSat.value = 1.0f;
    [self _sliderChanged];
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
    int hooks = [status[@"hooked_methods"] intValue];
    self.statusLabel.text = [NSString stringWithFormat:@"Camera: %@ [%@] hooks:%d",
                             active ? @"ON" : @"OFF", source, hooks];

    self.floatingButton.layer.borderColor = active
        ? [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1].CGColor
        : [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1].CGColor;

    NSDictionary *server = [NSDictionary dictionaryWithContentsOfFile:kServerPath];
    BOOL listening = [server[@"listening"] boolValue];
    int clients = [server[@"clients"] intValue];
    int port = [server[@"port"] intValue] ?: 1935;
    self.serverLabel.text = [NSString stringWithFormat:@"RTMP: %@ (:%d, %dc)",
                             listening ? @"UP" : @"DOWN", port, clients];
}

#pragma mark - Notifications

- (void)_registerNotifications {
    int token;
    notify_register_dispatch(kNotifStatusChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) { [self _refreshStatus]; });
    notify_register_dispatch(kNotifServerChanged.UTF8String, &token,
        dispatch_get_main_queue(), ^(int t) { [self _refreshStatus]; });
}

@end

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (![bundleID isEqualToString:@"com.apple.springboard"]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        [[VCFFloatingController shared] setup];
    });
}
