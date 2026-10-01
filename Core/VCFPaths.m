#import "VCFPaths.h"
#import <dlfcn.h>
#import <stdlib.h>

NSError *VCFError(NSString *message) {
    return [NSError errorWithDomain:@"VCamFree" code:1
                           userInfo:@{NSLocalizedDescriptionKey:message ?: @"Unknown error"}];
}

NSString *VCFStorageDirectory(NSError **error) {
    typedef const char *(*JBRootResolver)(const char *);
    JBRootResolver resolver = (JBRootResolver)dlsym(RTLD_DEFAULT, "jbroot");
    if (resolver) {
        const char *path = resolver("/var/mobile/Library/VCamFree");
        if (path && path[0] == '/') {
            NSString *resolved = [NSString stringWithUTF8String:path];
            if (resolved && ![resolved isEqualToString:@"/var/mobile/Library/VCamFree"])
                return resolved;
        }
    }

    Dl_info image = {0};
    if (dladdr((const void *)&VCFStorageDirectory, &image) && image.dli_fname) {
        NSString *folder = [[NSString stringWithUTF8String:image.dli_fname] stringByDeletingLastPathComponent];
        NSString *link = [folder stringByAppendingPathComponent:@".jbroot"];
        NSString *root = link.stringByResolvingSymlinksInPath;
        BOOL directory = NO;
        if (![root isEqualToString:link] &&
            [[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&directory] && directory)
            return [root stringByAppendingPathComponent:@"var/mobile/Library/VCamFree"];
    }

    NSString *hardcoded = @"/var/jb/var/mobile/Library/VCamFree";
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/var/jb" isDirectory:&isDir] && isDir)
        return hardcoded;

    if (error) *error = VCFError(@"Cannot find jailbreak root. Install via Sileo in an active bootstrap.");
    return nil;
}

NSString *VCFManagedMediaPath(NSString *name, NSError **error) {
    if (![name isKindOfClass:NSString.class] || !name.length ||
        ![name isEqualToString:name.lastPathComponent] ||
        [name containsString:@"/"] || [name containsString:@"\\"] ||
        name.length > 128) {
        if (error) *error = VCFError(@"Invalid media filename.");
        return nil;
    }
    NSString *base = VCFStorageDirectory(error);
    if (!base) return nil;
    return [[base stringByAppendingPathComponent:@"Media"] stringByAppendingPathComponent:name];
}
