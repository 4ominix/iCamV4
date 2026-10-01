#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSError *VCFError(NSString *message);
FOUNDATION_EXPORT NSString * _Nullable VCFStorageDirectory(NSError * _Nullable * _Nullable error);
FOUNDATION_EXPORT NSString * _Nullable VCFManagedMediaPath(NSString *name, NSError * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
