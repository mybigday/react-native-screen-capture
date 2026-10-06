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

/** Port objects identify the stream; names/device positions can be shared by different inputs. */
static NSString *RNSCVideoStreamIdentity(AVCaptureConnection *connection)
{
    NSMutableArray<NSString *> *ports = [NSMutableArray array];
    for (AVCaptureInputPort *port in connection.inputPorts)
    {
        if ([port.mediaType isEqualToString:AVMediaTypeVideo])
        {
            NSString *identity = [NSString stringWithFormat:@"%p", port];
            if (![ports containsObject:identity]) [ports addObject:identity];
        }
    }
    [ports sortUsingSelector:@selector(compare:)];
    return [ports componentsJoinedByString:@","];
}

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
    NSString *_streamIdentity;
    BOOL _multiCam;

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
    NSUInteger _presentations;
    NSUInteger _attachmentGeneration;
    /** The last discovery could not obtain an output for this stream. */
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
        _streamIdentity = RNSCVideoStreamIdentity(previewLayer.connection);
        _multiCam = [session isKindOfClass:AVCaptureMultiCamSession.class];
        // The preview graph can change during construction. Bind identity to the same
        // session/stream snapshot used for output selection, rather than reading it again.
        _identifier = [NSString stringWithFormat:@"camera:%p:stream:%@", session, _streamIdentity];
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

+ (NSString *)sourceIdentifierForPreview:(AVCaptureVideoPreviewLayer *)preview
{
    return [NSString stringWithFormat:@"camera:%p:stream:%@", preview.session,
                                      RNSCVideoStreamIdentity(preview.connection)];
}

- (BOOL)matchesPreview:(AVCaptureVideoPreviewLayer *)preview
{
    return preview.session != nil && _session == preview.session &&
           [_identifier isEqualToString:[self.class sourceIdentifierForPreview:preview]];
}

- (BOOL)matchesConnection:(AVCaptureConnection *)connection
{
    // Runs on the host's capture queue too; do not depend on its autorelease drain policy.
    @autoreleasepool
    {
        NSString *identity = RNSCVideoStreamIdentity(connection);
        if (_streamIdentity.length)
            return [_streamIdentity isEqualToString:identity];
        // An unidentified reader is only the inputless/unconnected synthetic fallback.
        return _session.inputs.count == 0 && identity.length == 0;
    }
}

- (BOOL)matchesOutput:(AVCaptureVideoDataOutput *)output
{
    if (!output) return NO;
    if (!_streamIdentity.length)
    {
        if (_session.inputs.count) return NO;
        for (AVCaptureConnection *connection in output.connections)
            if (RNSCVideoStreamIdentity(connection).length) return NO;
        return YES;
    }
    if (!output.connections.count) return NO;
    // An output carrying multiple streams cannot have separate delegate wrappers removed
    // independently. Borrow only an output whose connections all belong to this reader.
    for (AVCaptureConnection *connection in output.connections)
        if (![self matchesConnection:connection]) return NO;
    return YES;
}

- (BOOL)canCreateOutput
{
    if (!_multiCam && _streamIdentity.length) return YES;
    // MultiCam routing requires explicit host connections. An unidentified ordinary preview
    // also must not compete with a reader for an identified stream. Only the inputless,
    // unconnected synthetic fallback may create an output without a stream identity.
    if (_streamIdentity.length || _session.inputs.count) return NO;
    for (AVCaptureOutput *output in _session.outputs)
        for (AVCaptureConnection *connection in output.connections)
            if (RNSCVideoStreamIdentity(connection).length) return NO;
    return YES;
}

- (void)attach
{
    AVCaptureVideoDataOutput *active = _ownedOutput ?: _borrowedOutput;
    if (_attached && [_session.outputs containsObject:active] &&
        active.sampleBufferDelegate == self && [self matchesOutput:active])
        return;
    if (_attached || active)
        [self detach];
    _attachRefused = NO;
    AVCaptureSession *session = _session;
    if (!session) return;

    AVCaptureVideoDataOutput *existing = nil;
    for (AVCaptureOutput *output in session.outputs) {
        if ([output isKindOfClass:AVCaptureVideoDataOutput.class] &&
            [self matchesOutput:(AVCaptureVideoDataOutput *)output]) {
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
        _attached = YES;
        _attachmentGeneration++;
        os_unfair_lock_unlock(&_lock);
        [existing setSampleBufferDelegate:self queue:previousQueue ?: _queue];
        return;
    }

    if (![self canCreateOutput])
    {
        _attachRefused = YES;
        return;
    }
    AVCaptureVideoDataOutput *output = [[AVCaptureVideoDataOutput alloc] init];
    // Never hold on to more than the one frame we keep below.
    output.alwaysDiscardsLateVideoFrames = YES;
    output.videoSettings = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    };
    // A session at its output limit will not take another one. A later discovery can retry
    // if configuration changes. hasFrame stays NO, so no placeholder is installed and the preview
    // region falls back to whatever drawViewHierarchyInRect gives -- which dumpHierarchy
    // reports honestly as a matched component with hasFrame=no.
    if (![session canAddOutput:output]) {
        _attachRefused = YES;
        return;
    }

    // Record ownership before configuration: even a throwing commit must remain recoverable.
    os_unfair_lock_lock(&_lock);
    _ownedOutput = output;
    os_unfair_lock_unlock(&_lock);
    @try
    {
        [session beginConfiguration];
        @try
        {
            [session addOutput:output];
        }
        @finally
        {
            [session commitConfiguration];
        }
        if (![session.outputs containsObject:output] || ![self matchesOutput:output])
        {
            [self detach];
            _attachRefused = YES;
            return;
        }
    }
    @catch (NSException *exception)
    {
        @try
        {
            [self detach];
        }
        @catch (NSException *cleanup)
        { /* Keep ownership for retry. */
        }
        @throw exception;
    }
    os_unfair_lock_lock(&_lock);
    _attached = YES;
    _attachmentGeneration++;
    os_unfair_lock_unlock(&_lock);
    [output setSampleBufferDelegate:self queue:_queue];
}

- (NSUInteger)attachmentGeneration { return _attachmentGeneration; }

- (BOOL)matchesSession:(AVCaptureSession *)session
{
    return session != nil && _session == session;
}

- (void)retainPresentation
{
    _presentations++;
    [self attach];
}

- (void)releasePresentation
{
    if (_presentations)
        _presentations--;
    if (_presentations == 0)
        [self detach];
}

- (void)releasePresentationIfIdle
{
    if (_presentations == 0)
        [self detach];
}

- (void)detach
{
    os_unfair_lock_lock(&_lock);
    AVCaptureVideoDataOutput *borrowed = _borrowedOutput;
    AVCaptureVideoDataOutput *owned = _ownedOutput;
    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = _previousDelegate;
    dispatch_queue_t previousQueue = _previousQueue;
    // Refused attempts have no reader to invalidate. Repeated discovery must keep their
    // generation stable so capture can deliver its no-frame fallback.
    if (_attached)
        _attachmentGeneration++;
    _attached = NO;

    CVPixelBufferRef stale = _latest;
    _latest = NULL;
    os_unfair_lock_unlock(&_lock);
    if (stale) CVPixelBufferRelease(stale);

    AVCaptureSession *session = _session;
    @try
    {
        if (borrowed.sampleBufferDelegate == self)
        {
            [borrowed setSampleBufferDelegate:previous queue:previous ? previousQueue : nil];
        }
        if (owned)
        {
            [owned setSampleBufferDelegate:nil queue:NULL];
            if ([session.outputs containsObject:owned])
            {
                [session beginConfiguration];
                @try
                {
                    [session removeOutput:owned];
                }
                @finally
                {
                    [session commitConfiguration];
                }
            }
        }
    }
    @finally
    {
        BOOL restored = borrowed.sampleBufferDelegate != self;
        BOOL removed = ![session.outputs containsObject:owned];
        os_unfair_lock_lock(&_lock);
        if (restored)
        {
            _borrowedOutput = nil;
            _previousDelegate = nil;
            _previousQueue = nil;
        }
        if (removed)
            _ownedOutput = nil;
        os_unfair_lock_unlock(&_lock);
    }
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
    @try { return RNSCCreateImageFromPixelBuffer(buffer); }
    @finally { CVPixelBufferRelease(buffer); }
}

- (CALayerContentsGravity)contentsGravity
{
    return RNSCContentsGravityForVideoGravity(_previewLayer.videoGravity);
}

- (CATransform3D)contentsTransform
{
    return [self contentsTransformForPreview:_previewLayer];
}

- (CATransform3D)contentsTransformForPreview:(AVCaptureVideoPreviewLayer *)previewLayer
{
    // Sample buffers come out of the data output in the *capture* orientation, which is not
    // necessarily the orientation the preview layer is showing. Front cameras also mirror the
    // preview but not the buffers. Correct for the difference between the two connections;
    // when they already agree this collapses to the identity.
    AVCaptureConnection *preview = previewLayer.connection;
    AVCaptureConnection *output = nil;
    for (AVCaptureConnection *connection in (_ownedOutput ?: _borrowedOutput).connections)
        if ([self matchesConnection:connection]) { output = connection; break; }
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
    // Snapshot forwarding before processing; detach cannot replace the host for this callback.
    id<AVCaptureVideoDataOutputSampleBufferDelegate> previous = [self borrowedDelegate];
    BOOL matchingConnection = [self matchesConnection:connection];
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CVPixelBufferRef stale = NULL;
    os_unfair_lock_lock(&_lock);
    // Teardown and publication share the lock: a callback cannot retain a frame after detach.
    if (_attached && (output == _ownedOutput || output == _borrowedOutput) && pixelBuffer &&
        matchingConnection)
    {
        stale = _latest;
        _latest = CVPixelBufferRetain(pixelBuffer);
    }
    os_unfair_lock_unlock(&_lock);
    if (stale)
        CVPixelBufferRelease(stale);

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

@implementation RNSCCameraPresentation
{
    RNSCCameraFrameProvider *_source;
    __weak AVCaptureVideoPreviewLayer *_preview;
    __weak UIView *_view;
    BOOL _attached;
}
@synthesize identifier = _identifier;
- (instancetype)initWithSource:(RNSCCameraFrameProvider *)source
                       preview:(AVCaptureVideoPreviewLayer *)preview
                          view:(UIView *)view
{
    if ((self = [super init]))
    {
        _source = source;
        _preview = preview;
        _view = view;
        _identifier = [NSString
            stringWithFormat:@"camera:%p:view:%p:layer:%p", preview.session, view, preview];
    }
    return self;
}
- (void)dealloc
{
    [self detach];
}
- (UIView *)targetView
{
    return _view;
}
- (CALayer *)mediaLayer
{
    return _preview;
}
- (NSUInteger)attachmentGeneration { return _source.attachmentGeneration; }
- (BOOL)isAlive
{
    return _view.window != nil && [_source matchesPreview:_preview];
}
- (void)attach
{
    if (!_attached)
    {
        _attached = YES;
        [_source retainPresentation];
    }
    else
        [_source attach];
}
- (void)detach
{
    if (_attached)
    {
        _attached = NO;
        [_source releasePresentation];
    }
    else
        [_source releasePresentationIfIdle];
}
- (BOOL)hasFrame
{
    return [_source hasFrame];
}
- (CGImageRef)newFrameImage
{
    return [_source newFrameImage];
}
- (CALayerContentsGravity)contentsGravity
{
    return RNSCContentsGravityForVideoGravity(_preview.videoGravity);
}
- (CATransform3D)contentsTransform
{
    return [_source contentsTransformForPreview:_preview];
}
@end

#endif // !TARGET_OS_TV
