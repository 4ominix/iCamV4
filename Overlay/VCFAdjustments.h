#import <UIKit/UIKit.h>
@interface VCFAdjustments : UIView
@property (nonatomic, copy) void (^didChange)(NSError *error);
@property (nonatomic, copy) void (^didClose)(void);
- (void)refresh;
@end
