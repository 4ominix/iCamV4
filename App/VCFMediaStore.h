#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, VCFMediaType) {
    VCFMediaTypeImage,
    VCFMediaTypeVideo
};

@interface VCFMediaItem : NSObject
@property (nonatomic, copy)   NSString    *filename;
@property (nonatomic, copy)   NSString    *fullPath;
@property (nonatomic, assign) VCFMediaType type;
@property (nonatomic, assign) uint64_t     fileSize;
@end

@interface VCFMediaStore : NSObject
@property (nonatomic, readonly) NSArray<VCFMediaItem *> *items;
+ (instancetype)shared;
- (void)reload;
- (VCFMediaItem *)importImage:(UIImage *)image withName:(NSString *)name;
- (VCFMediaItem *)importFileAtURL:(NSURL *)url;
- (BOOL)deleteItem:(VCFMediaItem *)item;
@end
