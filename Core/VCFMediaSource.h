#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
NS_ASSUME_NONNULL_BEGIN
@interface VCFMediaSource : NSObject
@property (nonatomic, readonly, strong, nullable) NSError *error;
@property (nonatomic, readonly) BOOL video;
- (nullable instancetype)initWithPath:(NSString *)path kind:(NSString *)kind
                                error:(NSError * _Nullable * _Nullable)error;
- (nullable CIImage *)imageAtTime:(double)time loop:(BOOL)loop;
@end
NS_ASSUME_NONNULL_END
