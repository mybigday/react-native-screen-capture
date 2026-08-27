//
//  RNSCCameraFrameProvider.m
//  ScreenCapture
//

#import "RNSCCameraFrameProvider.h"
#import <os/lock.h>

@interface RNSCCameraFrameProvider () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation RNSCCameraFrameProvider {
    __weak AVCaptureVideoPreviewLayer *_previewLayer;
    __weak UIView *_targetView;
    __weak AVCaptureSession *_session;

    /** An output we added ourselves and therefore must remove again. */
    AVCaptureVideoDataOutput *_ownedOutput;
    /** An output that belongs to the host; we only borrow its delegate. */
    AVCaptureVideoDataOutput *_borrowedOutput;
    __weak id<AVCaptureVideoDataOutputSampleBufferDelegate> _previousDelegate;
    dispatch_queue_t _previousQueue;

    dispatch_queue_t _queue;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached;
}

@synthesize identifier = _identifier;

- (nullable instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer
                                   targetView:(UIView *)targetView
{
    AVCaptureSession *session = previewLayer.session;
    if (!session) return nil;

    self = [super init];
    if (self) {
        _previewLayer = previewLayer;
        _targetView = targetView;
        _session = session;
        _identifier = [NSString stringWithFormat:@"camera:%p", session];
        _queue = dispatch_queue_create("com.fugood.screencapture.camera", DISPATCH_QUEUE_SERIAL);
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)dealloc
{
    [self detach];
    if (_latest) CVPixelBufferRelease(_latest);
}

#pragma mark - RNSCFrameProvider

- (UIView *)targetView { return _targetView; }
- (CALayer *)mediaLayer { return _previewLayer; }
- (BOOL)isAlive { return _targetView != nil && _previewLayer != nil && _session != nil; }

- (void)attach
{
    if (_attached) return;
    AVCaptureSession *session = _session;
    if (!session) return;

    AVCaptureVideoDataOutput *existing = nil;
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) {
            existing = (AVCaptureVideoDataOutput *)output;
            break;
        }
    }

    if (existing) {
        // Prefer borrowing: reconfiguring somebody else's live session causes a visible glitch
        // and can fail outright on some presets. Wrapping the delegate disturbs nothing, and we
        // forward every callback so the host keeps working exactly as before.
        _borrowedOutput = existing;
        _previousDelegate = existing.sampleBufferDelegate;
        _previousQueue = existing.sampleBufferCallbackQueue;
        [existing setSampleBufferDelegate:self queue:_previousQueue ?: _queue];
        _attached = YES;
        return;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    // Never hold on to more than the one frame we keep below.
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    if (![session canAddOutput:output]) return;

    [session beginConfiguration];
    [session addOutput:output];
    [session commitConfiguration];
    if (![session.outputs containsObject:output]) return;

    _ownedOutput = output;
    [output setSampleBufferDelegate:self queue:_queue];
    _attached = YES;
}

- (void)detach
{
    if (!_attached) return;
    _attached = NO;

    if (_borrowedOutput) {
        [_borrowedOutput setSampleBufferDelegate:_previousDelegate queue:_previousQueue];
        _borrowedOutput = nil;
        _previousDelegate = nil;
        _previousQueue = nil;
    }

    if (_ownedOutput) {
        AVCaptureSession *session = _session;
        [_ownedOutput setSampleBufferDelegate:nil queue:NULL];
        if (session) {
            [session beginConfiguration];
            [session removeOutput:_ownedOutput];
            [session commitConfiguration];
        }
        _ownedOutput = nil;
    }

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef stale = _latest;
    _latest = NULL;
    os_unfair_lock_unlock(&_lock);
    if (stale) CVPixelBufferRelease(stale);
}

- (BOOL)hasFrame
{
    os_unfair_lock_lock(&_lock);
    BOOL has = _latest != NULL;
    os_unfair_lock_unlock(&_lock);
    return has;
}

- (CGImageRef _Nullable)newFrameImage
{
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef buffer = _latest ? CVPixelBufferRetain(_latest) : NULL;
    os_unfair_lock_unlock(&_lock);
    if (!buffer) return NULL;
    CGImageRef image = RNSCCreateImageFromPixelBuffer(buffer);
    CVPixelBufferRelease(buffer);
    return image;
}

- (CALayerContentsGravity)contentsGravity
{
    return RNSCContentsGravityForVideoGravity(_previewLayer.videoGravity);
}

- (CATransform3D)contentsTransform
{
    // Sample buffers come out of the data output in the *capture* orientation, which is not
    // necessarily the orientation the preview layer is showing. Front cameras also mirror the
    // preview but not the buffers. Correct for the difference between the two connections;
    // when they already agree this collapses to the identity.
    AVCaptureConnection *preview = _previewLayer.connection;
    AVCaptureConnection *output = (_ownedOutput ?: _borrowedOutput).connections.firstObject;
    if (!preview || !output) return CATransform3DIdentity;

    CGFloat angle = 0;
    if (@available(iOS 17.0, tvOS 17.0, *)) {
        angle = preview.videoRotationAngle - output.videoRotationAngle;
    }

    CATransform3D transform = CATransform3DIdentity;
    if (angle != 0) {
        transform = CATransform3DRotate(transform, angle * M_PI / 180.0, 0, 0, 1);
    }
    if (preview.isVideoMirrored != output.isVideoMirrored) {
        transform = CATransform3DScale(transform, -1, 1, 1);
    }
    return transform;
}

#pragma mark - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection
{
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (pixelBuffer) {
        CVPixelBufferRetain(pixelBuffer);
        os_unfair_lock_lock(&_lock);
        CVPixelBufferRef stale = _latest;
        _latest = pixelBuffer;
        os_unfair_lock_unlock(&_lock);
        if (stale) CVPixelBufferRelease(stale);
    }

    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = _previousDelegate;
    if ([previous respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [previous captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = _previousDelegate;
    if ([previous respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [previous captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end
