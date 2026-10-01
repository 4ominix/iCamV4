#import "VCFMediaStore.h"

static NSString *const kMediaDir = @"/var/jb/var/mobile/Library/VCamFree/Media";

@implementation VCFMediaItem
@end

@implementation VCFMediaStore {
    NSMutableArray<VCFMediaItem *> *_items;
}

+ (instancetype)shared {
    static VCFMediaStore *inst;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mediaDirectory = kMediaDir;
        _items = [NSMutableArray array];
        [[NSFileManager defaultManager] createDirectoryAtPath:kMediaDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        [self reload];
    }
    return self;
}

- (NSArray<VCFMediaItem *> *)items {
    return [_items copy];
}

- (void)reload {
    [_items removeAllObjects];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kMediaDir error:nil];
    for (NSString *f in files) {
        if ([f hasPrefix:@"."]) continue;
        NSString *fullPath = [kMediaDir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];

        VCFMediaItem *item = [[VCFMediaItem alloc] init];
        item.filename = f;
        item.fullPath = fullPath;
        item.fileSize = [attrs[NSFileSize] unsignedLongLongValue];

        NSString *ext = f.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] ||
            [ext isEqualToString:@"m4v"] || [ext isEqualToString:@"avi"]) {
            item.type = VCFMediaTypeVideo;
        } else {
            item.type = VCFMediaTypeImage;
        }
        [_items addObject:item];
    }
    [_items sortUsingComparator:^NSComparisonResult(VCFMediaItem *a, VCFMediaItem *b) {
        return [a.filename localizedCaseInsensitiveCompare:b.filename];
    }];
}

- (VCFMediaItem *)importImage:(UIImage *)image withName:(NSString *)name {
    if (!image || !name) return nil;

    NSString *ext = name.pathExtension.lowercaseString;
    NSData *data;
    if ([ext isEqualToString:@"png"]) {
        data = UIImagePNGRepresentation(image);
    } else {
        data = UIImageJPEGRepresentation(image, 0.92);
        if (!ext.length || ![ext isEqualToString:@"jpg"]) {
            name = [[name stringByDeletingPathExtension] stringByAppendingPathExtension:@"jpg"];
        }
    }
    if (!data) return nil;

    NSString *dest = [kMediaDir stringByAppendingPathComponent:name];
    int suffix = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
        NSString *base = [name stringByDeletingPathExtension];
        NSString *newName = [NSString stringWithFormat:@"%@_%d.%@", base, suffix++, name.pathExtension];
        dest = [kMediaDir stringByAppendingPathComponent:newName];
    }

    [data writeToFile:dest atomically:YES];
    [self reload];

    for (VCFMediaItem *item in _items) {
        if ([item.fullPath isEqualToString:dest]) return item;
    }
    return nil;
}

- (VCFMediaItem *)importFileAtURL:(NSURL *)url {
    if (!url) return nil;
    NSString *name = url.lastPathComponent;
    NSString *dest = [kMediaDir stringByAppendingPathComponent:name];

    int suffix = 1;
    while ([[NSFileManager defaultManager] fileExistsAtPath:dest]) {
        NSString *base = [name stringByDeletingPathExtension];
        NSString *newName = [NSString stringWithFormat:@"%@_%d.%@", base, suffix++, name.pathExtension];
        dest = [kMediaDir stringByAppendingPathComponent:newName];
    }

    NSError *err;
    BOOL ok;
    if ([url startAccessingSecurityScopedResource]) {
        ok = [[NSFileManager defaultManager] copyItemAtURL:url
                                                     toURL:[NSURL fileURLWithPath:dest]
                                                     error:&err];
        [url stopAccessingSecurityScopedResource];
    } else {
        ok = [[NSFileManager defaultManager] copyItemAtURL:url
                                                     toURL:[NSURL fileURLWithPath:dest]
                                                     error:&err];
    }
    if (!ok) return nil;

    [self reload];
    for (VCFMediaItem *item in _items) {
        if ([item.fullPath isEqualToString:dest]) return item;
    }
    return nil;
}

- (BOOL)deleteItem:(VCFMediaItem *)item {
    if (!item) return NO;
    BOOL ok = [[NSFileManager defaultManager] removeItemAtPath:item.fullPath error:nil];
    if (ok) [self reload];
    return ok;
}

@end
