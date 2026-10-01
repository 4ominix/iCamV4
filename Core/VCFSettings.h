#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSDictionary *VCFDefaults(void);
FOUNDATION_EXPORT NSDictionary *VCFNormalize(NSDictionary *input);
FOUNDATION_EXPORT NSDictionary *VCFReadSettings(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT BOOL VCFUpdateSettings(void (^edit)(NSMutableDictionary *settings),
                                          NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString * const VCFSettingsNotification;
NS_ASSUME_NONNULL_END
