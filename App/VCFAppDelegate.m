#import <UIKit/UIKit.h>

@interface VCFAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@interface VCFMainViewController : UIViewController
@end

@implementation VCFAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    VCFMainViewController *mainVC = [[VCFMainViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:mainVC];
    nav.navigationBar.prefersLargeTitles = YES;

    // dark theme
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([VCFAppDelegate class]));
    }
}
