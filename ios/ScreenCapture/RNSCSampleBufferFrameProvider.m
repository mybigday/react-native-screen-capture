//
//  RNSCSampleBufferFrameProvider.m
//  ScreenCapture
//

#import "RNSCSampleBufferFrameProvider.h"
#import <os/lock.h>

@implementation RNSCSampleBufferFrameProvider {
    __weak AVSampleBufferDisplayLayer *_layer;
    __weak UIView *_targetView;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
}

@synthesize identifier = _identifier;

- (nullable instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)layer
                                   targetView:(UIView *)targetView
{
    if (!layer) return nil;
    // sampleBufferRenderer is iOS 17.0, copyDisplayedPixelBuffer on it is 17.4. Below that
    // there is no public read-back at all.
    if (@available(iOS 17.4, tvOS 17.4, *)) {
        // supported
    } else {
        return nil;
    }

    self = [super init];
    if (self) {
        _layer = layer;
        _targetView = targetView;
        _identifier = [NSString stringWithFormat:@"samplebuffer:%p", layer];
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc
{
    if (_latest) CVPixelBufferRelease(_latest);
}

#pragma mark - RNSCFrameProvider

- (UIView *)targetView { return _targetView; }
- (CALayer *)mediaLayer { return _layer; }
- (BOOL)isAlive { return _targetView != nil && _layer != nil; }
- (CATransform3D)contentsTransform { return CATransform3DIdentity; }

- (CALayerContentsGravity)contentsGravity
{
    return RNSCContentsGravityForVideoGravity(_layer.videoGravity);
}

/** Nothing to hook: the frame is read on demand, so there is no cost to leave attached. */
- (void)attach {}

- (void)detach
{
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef stale = _latest;
    _latest = NULL;
    os_unfair_lock_unlock(&_lock);
    if (stale) CVPixelBufferRelease(stale);
}

/** Reads the displayed buffer and keeps it, so hasFrame and newFrameImage agree. */
- (void)pump
{
    AVSampleBufferDisplayLayer *layer = _layer;
    if (!layer) return;
    CVPixelBufferRef buffer = NULL;
    if (@available(iOS 17.4, tvOS 17.4, *)) {
        buffer = [layer.sampleBufferRenderer copyDisplayedPixelBuffer];
    }
    if (!buffer) return;

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef stale = _latest;
    _latest = buffer;
    os_unfair_lock_unlock(&_lock);
    if (stale) CVPixelBufferRelease(stale);
}

- (BOOL)hasFrame
{
    [self pump];
    os_unfair_lock_lock(&_lock);
    BOOL has = _latest != NULL;
    os_unfair_lock_unlock(&_lock);
    return has;
}

- (CGImageRef _Nullable)newFrameImage
{
    [self pump];
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef buffer = _latest ? CVPixelBufferRetain(_latest) : NULL;
    os_unfair_lock_unlock(&_lock);
    if (!buffer) return NULL;
    CGImageRef image = RNSCCreateImageFromPixelBuffer(buffer);
    CVPixelBufferRelease(buffer);
    return image;
}

@end
