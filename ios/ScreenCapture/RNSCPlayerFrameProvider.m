//
//  RNSCPlayerFrameProvider.m
//  ScreenCapture
//

#import "RNSCPlayerFrameProvider.h"
#import <os/lock.h>

@implementation RNSCPlayerFrameProvider {
    // Weak: the registry keeps providers around for a few idle seconds after a capture, and a
    // strong reference here would keep the host's player -- and its audio -- alive that whole
    // time after the host had let go of it.
    __weak AVPlayer *_player;
    __weak UIView *_targetView;
    __weak CALayer *_mediaLayer;
    CALayerContentsGravity _gravity;

    AVPlayerItemVideoOutput *_output;
    __weak AVPlayerItem *_observedItem;

    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached;
}

@synthesize identifier = _identifier;

- (nullable instancetype)initWithPlayer:(AVPlayer *)player
                             targetView:(UIView *)targetView
                             mediaLayer:(nullable CALayer *)mediaLayer
                                gravity:(CALayerContentsGravity)gravity
{
    if (!player) return nil;
    self = [super init];
    if (self) {
        _player = player;
        _targetView = targetView;
        _mediaLayer = mediaLayer;
        _gravity = gravity ?: kCAGravityResizeAspect;
        _identifier = [NSString stringWithFormat:@"player:%p", player];
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
- (CALayer *)mediaLayer { return _mediaLayer; }
- (BOOL)isAlive { return _targetView != nil && _player != nil; }
- (CALayerContentsGravity)contentsGravity { return _gravity; }
- (CATransform3D)contentsTransform { return CATransform3DIdentity; }

- (void)attach
{
    if (_attached) return;
    _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)
    }];
    // The output is bound to the current item lazily, in -pump.
    _attached = YES;
}

- (void)detach
{
    if (!_attached) return;
    _attached = NO;

    [self detachOutputFromObservedItem];
    _output = nil;

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef stale = _latest;
    _latest = NULL;
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

#pragma mark - Internals

/** Pulls a new frame if the output has one, otherwise keeps the last we saw. */
- (void)pump
{
    AVPlayerItemVideoOutput *output = _output;
    if (!output) return;
    [self bindOutputToCurrentItem];

    CMTime itemTime = [output itemTimeForHostTime:CACurrentMediaTime()];

    // `hasNewPixelBuffer` is false for a paused player -- its item time does not advance -- but
    // the currently displayed frame is still there for the taking. Treat the flag as an
    // optimisation for when we already hold something, not as a precondition.
    BOOL haveFrame;
    os_unfair_lock_lock(&_lock);
    haveFrame = _latest != NULL;
    os_unfair_lock_unlock(&_lock);
    if (haveFrame && ![output hasNewPixelBufferForItemTime:itemTime]) return;

    CVPixelBufferRef buffer = [output copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (!buffer) return;

    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef stale = _latest;
    _latest = buffer;
    os_unfair_lock_unlock(&_lock);
    if (stale) CVPixelBufferRelease(stale);
}

/**
 * Binds the output to whatever item the player is on now.
 *
 * <p>Polled from -pump rather than driven by KVO on {@code currentItem}: that notification
 * arrives on whatever thread advanced the queue, which races -detach and -pump, and registering
 * as an observer is what forced this class to retain the host's player in the first place.
 * -pump already runs before every read, so the item is never stale by the time it matters.
 */
- (void)bindOutputToCurrentItem
{
    AVPlayer *player = _player;
    AVPlayerItem *item = player.currentItem;
    if (item == _observedItem) return;

    // Playlists swap the item out from under us; move the output across when they do.
    [self detachOutputFromObservedItem];
    if (item && ![item.outputs containsObject:_output]) {
        [item addOutput:_output];
        _observedItem = item;
    }
}

- (void)detachOutputFromObservedItem
{
    AVPlayerItem *item = _observedItem;
    if (item && _output && [item.outputs containsObject:_output]) {
        [item removeOutput:_output];
    }
    _observedItem = nil;
}

@end
