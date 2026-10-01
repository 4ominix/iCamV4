#import "VCFRender.h"
#import "VCFGeometry.h"

CIImage *VCFCompose(CIImage *image, CGSize size, NSDictionary *settings) {
    CGRect r = image.extent;
    if (!image || CGRectIsInfinite(r) || CGRectIsEmpty(r) ||
        !isfinite(r.origin.x) || !isfinite(r.origin.y)) return nil;

    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-r.origin.x, -r.origin.y)];

    VCFMatrix m = VCFGeometry(r.size.width, r.size.height, size.width, size.height,
                              [settings[@"Rotation"] intValue],
                              [settings[@"Mirror"] boolValue],
                              [settings[@"Fill"] boolValue],
                              [settings[@"Zoom"] doubleValue],
                              [settings[@"X"] doubleValue],
                              [settings[@"Y"] doubleValue]);
    if (m.a == 0 && m.b == 0) return nil;

    CGRect viewport = CGRectMake(0, 0, size.width, size.height);
    CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
                      imageByCroppingToRect:viewport];
    image = [image imageByApplyingTransform:CGAffineTransformMake(m.a, m.b, m.c, m.d, m.tx, m.ty)];
    return [[image imageByCompositingOverImage:black] imageByCroppingToRect:viewport];
}
