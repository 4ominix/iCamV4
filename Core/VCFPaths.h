#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSError *VCFError(NSString *message);
FOUNDATION_EXPORT NSString * _Nullable VCFStorageDirectory(NSError **error);
FOUNDATION_EXPORT NSString * _Nullable VCFManagedMediaPath(NSString *name, NSError **error);
