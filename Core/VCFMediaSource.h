#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>

@interface VCFMediaSource : NSObject
@property (nonatomic, readonly, strong) NSError *error;
@property (nonatomic, readonly) BOOL video;
- (instancetype)initWithPath:(NSString *)path kind:(NSString *)kind error:(NSError **)error;
- (CIImage *)imageAtTime:(double)time loop:(BOOL)loop;
@end
