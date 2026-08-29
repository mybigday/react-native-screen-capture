//
//  RNSCCameraFrameProvider.m
//  ScreenCapture
//

#import "RNSCCameraFrameProvider.h"

// AVCaptureSession and AVCaptureVideoPreviewLayer are API_UNAVAILABLE(tvos):
// tvOS has no camera. Video capture still works there through AVPlayerLayer.
#if !TARGET_OS_TV

#import <os/lock.h>

@interface RNSCCameraFrameProvider () <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

/**
 * The pre-iOS-17 spelling of videoRotationAngle, in the same degrees so the two paths can be
 * compared the same way. Only the difference between two connections is used, so all that
 * matters is that the mapping is consistent.
 */
API_DEPRECATED_WITH_REPLACEMENT("videoRotationAngle", ios(6.0, 17.0))
static CGFloat RNSCAngleForVideoOrientation(AVCaptureVideoOrientation orientation)
{
    switch (orientation) {
        case AVCaptureVideoOrientationPortrait: return 90;
        case AVCaptureVideoOrientationPortraitUpsideDown: return 270;
        case AVCaptureVideoOrientationLandscapeRight: return 0;
        case AVCaptureVideoOrientationLandscapeLeft: return 180;
    }
    return 0;
}

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
    /** Set when the session refused another output, so we stop re-probing it every capture. */
    BOOL _attachRefused;
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
    if (_attached || _attachRefused) return;
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
        dispatch_queue_t previousQueue = existing.sampleBufferCallbackQueue;
        os_unfair_lock_lock(&_lock);
        _borrowedOutput = existing;
        _previousDelegate = existing.sampleBufferDelegate;
        _previousQueue = previousQueue;
        os_unfair_lock_unlock(&_lock);
        [existing setSampleBufferDelegate:self queue:previousQueue ?: _queue];
        _attached = YES;
        return;
    }

    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    // Never hold on to more than the one frame we keep below.
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    // A session at its output limit will not take another one, and will not start to later in
    // this session's life. hasFrame stays NO, so no placeholder is installed and the preview
    // region falls back to whatever drawViewHierarchyInRect gives -- which dumpHierarchy
    // reports honestly as a matched component with hasFrame=no.
    if (![session canAddOutput:output]) {
        _attachRefused = YES;
        return;
    }

    [session beginConfiguration];
    [session addOutput:output];
    [session commitConfiguration];
    if (![session.outputs containsObject:output]) {
        _attachRefused = YES;
        return;
    }

    _ownedOutput = output;
    [output setSampleBufferDelegate:self queue:_queue];
    _attached = YES;
}

- (void)detach
{
    if (!_attached) return;
    _attached = NO;

    if (_borrowedOutput) {
        // Only put back what we took. If the host swapped its own delegate in while we were
        // attached, restoring ours would silently disconnect them.
        if (_borrowedOutput.sampleBufferDelegate == self) {
            // AVFoundation requires (delegate != nil) == (queue != nil) and raises otherwise.
            // _previousDelegate is weak, so it can be nil here even though _previousQueue is
            // still very much alive.
            id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = _previousDelegate;
            [_borrowedOutput setSampleBufferDelegate:previous
                                               queue:previous ? _previousQueue : nil];
        }
        // Under the lock: -captureOutput:... reads these on the capture queue, and a
        // concurrent read of a __weak ivar while it is being written is an unsafe access to
        // the weak table, not merely a stale value.
        os_unfair_lock_lock(&_lock);
        _borrowedOutput = nil;
        _previousDelegate = nil;
        _previousQueue = nil;
        os_unfair_lock_unlock(&_lock);
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
    } else {
        // videoRotationAngle is iOS 17+, but the podspec targets 15.1: without this the
        // correction was simply dead on 15 and 16, and a front camera in landscape came back
        // rotated a quarter turn.
        angle = RNSCAngleForVideoOrientation(preview.videoOrientation)
              - RNSCAngleForVideoOrientation(output.videoOrientation);
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

/**
 * The host delegate we are forwarding to, read under the lock.
 *
 * <p>These callbacks arrive on the capture queue while -detach runs on the main thread. Reading
 * a __weak ivar concurrently with the write that clears it is an unsafe access to the weak
 * table, so the load takes the same lock the write does and hands back a strong reference.
 */
- (nullable id<AVCaptureVideoDataOutputSampleBufferDelegate>)borrowedDelegate
{
    os_unfair_lock_lock(&_lock);
    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = _previousDelegate;
    os_unfair_lock_unlock(&_lock);
    return previous;
}

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

    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = [self borrowedDelegate];
    if ([previous respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [previous captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection
{
    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = [self borrowedDelegate];
    if ([previous respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [previous captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

#endif // !TARGET_OS_TV
