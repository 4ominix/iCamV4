#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSDictionary *VCFDefaults(void);
FOUNDATION_EXPORT NSDictionary *VCFNormalize(NSDictionary *input);
FOUNDATION_EXPORT NSDictionary *VCFReadSettings(NSError **error);
FOUNDATION_EXPORT BOOL VCFUpdateSettings(void (^edit)(NSMutableDictionary *settings), NSError **error);
FOUNDATION_EXPORT NSString * const VCFSettingsNotification;
