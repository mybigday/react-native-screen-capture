//
//  RNSCFrameProvider.m
//  ScreenCapture
//

#import "RNSCFrameProvider.h"
#import <Metal/Metal.h>

CIContext *RNSCSharedCIContext(void)
{
    static CIContext *context = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device) {
            context = [CIContext contextWithMTLDevice:device
                                              options:@{kCIContextWorkingColorSpace: [NSNull null]}];
        }
        if (!context) {
            context = [CIContext contextWithOptions:nil];
        }
    });
    return context;
}

CGImageRef RNSCCreateImageFromPixelBuffer(CVPixelBufferRef buffer)
{
    if (!buffer) return NULL;
    CIImage *ciImage = [CIImage imageWithCVPixelBuffer:buffer];
    if (!ciImage) return NULL;
    return [RNSCSharedCIContext() createCGImage:ciImage fromRect:ciImage.extent];
}

CALayerContentsGravity RNSCContentsGravityForVideoGravity(AVLayerVideoGravity gravity)
{
    if ([gravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) {
        return kCAGravityResizeAspectFill;
    }
    if ([gravity isEqualToString:AVLayerVideoGravityResize]) {
        return kCAGravityResize;
    }
    return kCAGravityResizeAspect;
}
