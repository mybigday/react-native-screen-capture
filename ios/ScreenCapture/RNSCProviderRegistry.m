//
//  RNSCProviderRegistry.m
//  ScreenCapture
//

#import "RNSCProviderRegistry.h"
#import "RNSCCameraFrameProvider.h"
#import "RNSCPlayerFrameProvider.h"

#if __has_include(<AVKit/AVKit.h>)
#import <AVKit/AVKit.h>
#define RNSC_HAS_AVKIT 1
#endif

/** How long the providers stay attached after the last capture. */
static const NSTimeInterval kIdleDetachDelay = 3.0;

/** The media layer classes discovery and dumpHierarchy both have to recognise. */
typedef NS_ENUM(NSInteger, RNSCMediaLayerKind) {
    RNSCMediaLayerKindNone = 0,
#if !TARGET_OS_TV
    RNSCMediaLayerKindCameraPreview,
#endif
    RNSCMediaLayerKindPlayer,
    RNSCMediaLayerKindSampleBufferDisplay,
};

@implementation RNSCProviderRegistry {
    NSMutableDictionary<NSString *, id<RNSCFrameProvider>> *_providers;
    NSTimer *_idleTimer;
}

+ (RNSCProviderRegistry *)sharedRegistry
{
    static RNSCProviderRegistry *registry = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registry = [[RNSCProviderRegistry alloc] init];
    });
    return registry;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _providers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - Public

- (NSArray<id<RNSCFrameProvider>> *)attachedProvidersForWindows:(NSArray<UIWindow *> *)windows
{
    [_idleTimer invalidate];
    _idleTimer = nil;

    NSMutableArray<id<RNSCFrameProvider>> *found = [NSMutableArray array];
    for (UIWindow *window in windows) {
        [self discoverInView:window into:found];
    }

    // Drop providers for components that have gone away.
    NSMutableSet<NSString *> *live = [NSMutableSet set];
    for (id<RNSCFrameProvider> provider in found) [live addObject:provider.identifier];
    for (NSString *key in _providers.allKeys) {
        id<RNSCFrameProvider> provider = _providers[key];
        if (![live containsObject:key] || !provider.isAlive) {
            [provider detach];
            [_providers removeObjectForKey:key];
        }
    }

    for (id<RNSCFrameProvider> provider in found) [provider attach];
    return found;
}

- (void)scheduleIdleDetach
{
    [_idleTimer invalidate];
    __weak __typeof(self) weakSelf = self;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:kIdleDetachDelay
                                                 repeats:NO
                                                   block:^(NSTimer *timer) {
        [weakSelf detachAll];
    }];
}

- (void)detachAll
{
    [_idleTimer invalidate];
    _idleTimer = nil;
    for (id<RNSCFrameProvider> provider in _providers.allValues) [provider detach];
    [_providers removeAllObjects];
}

#pragma mark - Discovery

- (void)discoverInView:(UIView *)view into:(NSMutableArray<id<RNSCFrameProvider>> *)found
{
    if (view.hidden || view.alpha <= 0.01) return;

    [self inspectLayer:view.layer forView:view into:found];

#ifdef RNSC_HAS_AVKIT
    // AVPlayerViewController does not expose its layer, but it is the view's next responder
    // and `player` is public. This is what react-native-video renders through.
    UIResponder *next = view.nextResponder;
    if ([next isKindOfClass:AVPlayerViewController.class]) {
        AVPlayerViewController *controller = (AVPlayerViewController *)next;
        if (controller.view == view && controller.player) {
            [self addProviderWithIdentifier:[NSString stringWithFormat:@"player:%p", controller.player]
                                       into:found
                                    builder:^id<RNSCFrameProvider> {
                return [[RNSCPlayerFrameProvider alloc]
                    initWithPlayer:controller.player
                        targetView:view
                        mediaLayer:nil
                           gravity:RNSCContentsGravityForVideoGravity(controller.videoGravity)];
            }];
        }
    }
#endif

    for (UIView *subview in view.subviews) [self discoverInView:subview into:found];
}

/**
 * Walks a view's own layers and reports the media ones.
 *
 * <p>Discovery and {@code dumpHierarchy} must agree on what counts as a media layer, or the
 * dump starts claiming components that capture cannot actually reach. They share this walk so
 * that adding a layer class is one edit, not two that have to stay in step.
 */
- (void)enumerateMediaLayersIn:(CALayer *)layer
                         using:(void (^)(CALayer *layer, RNSCMediaLayerKind kind))block
{
    RNSCMediaLayerKind kind = RNSCMediaLayerKindNone;
#if !TARGET_OS_TV
    if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class]) {
        kind = RNSCMediaLayerKindCameraPreview;
    } else
#endif
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        kind = RNSCMediaLayerKindPlayer;
    } else if ([NSStringFromClass(layer.class) containsString:@"AVSampleBufferDisplayLayer"]) {
        kind = RNSCMediaLayerKindSampleBufferDisplay;
    }
    if (kind != RNSCMediaLayerKindNone) block(layer, kind);

    for (CALayer *sublayer in layer.sublayers) {
        // Subviews own their layers; discoverInView: will reach those on its own.
        if ([sublayer.delegate isKindOfClass:UIView.class]) continue;
        [self enumerateMediaLayersIn:sublayer using:block];
    }
}

- (void)inspectLayer:(CALayer *)layer
             forView:(UIView *)view
                into:(NSMutableArray<id<RNSCFrameProvider>> *)found
{
    [self enumerateMediaLayersIn:layer using:^(CALayer *media, RNSCMediaLayerKind kind) {
        switch (kind) {
#if !TARGET_OS_TV
            case RNSCMediaLayerKindCameraPreview: {
                AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)media;
                if (!preview.session) return;
                NSString *identifier =
                    [NSString stringWithFormat:@"camera:%p", preview.session];
                [self addProviderWithIdentifier:identifier
                                           into:found
                                        builder:^id<RNSCFrameProvider> {
                    return [[RNSCCameraFrameProvider alloc] initWithPreviewLayer:preview
                                                                      targetView:view];
                }];
                return;
            }
#endif
            case RNSCMediaLayerKindPlayer: {
                AVPlayerLayer *playerLayer = (AVPlayerLayer *)media;
                if (!playerLayer.player) return;
                NSString *identifier =
                    [NSString stringWithFormat:@"player:%p", playerLayer.player];
                [self addProviderWithIdentifier:identifier
                                           into:found
                                        builder:^id<RNSCFrameProvider> {
                    return [[RNSCPlayerFrameProvider alloc]
                        initWithPlayer:playerLayer.player
                            targetView:view
                            mediaLayer:playerLayer
                               gravity:RNSCContentsGravityForVideoGravity(playerLayer.videoGravity)];
                }];
                return;
            }
            default:
                // Recognised by the dump, not yet captured.
                return;
        }
    }];
}

- (void)addProviderWithIdentifier:(NSString *)identifier
                             into:(NSMutableArray<id<RNSCFrameProvider>> *)found
                          builder:(id<RNSCFrameProvider> _Nullable (^)(void))builder
{
    for (id<RNSCFrameProvider> existing in found) {
        if ([existing.identifier isEqualToString:identifier]) return;
    }

    id<RNSCFrameProvider> cached = _providers[identifier];
    if (cached && cached.isAlive) {
        [found addObject:cached];
        return;
    }

    id<RNSCFrameProvider> provider = builder();
    if (!provider) return;
    // Detach the dead one we are about to displace. Once the key points elsewhere the prune
    // loop can no longer see it, and -dealloc is too late for the camera provider: it restores
    // the host's delegate only when the output still points at it, and AVFoundation holds the
    // delegate weakly, so by dealloc that check can never match.
    if (cached) [cached detach];
    _providers[identifier] = provider;
    [found addObject:provider];
}

#pragma mark - Debugging

- (NSString *)describeWindows:(NSArray<UIWindow *> *)windows
{
    NSMutableString *out = [NSMutableString string];
    for (UIWindow *window in windows) {
        [out appendFormat:@"WINDOW %@ level=%.0f\n",
            NSStringFromCGRect(window.frame), (double)window.windowLevel];
        [self describeView:window depth:1 into:out];
    }
    return out;
}

- (void)describeView:(UIView *)view depth:(NSInteger)depth into:(NSMutableString *)out
{
    for (NSInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ layer=%@", NSStringFromClass(view.class), NSStringFromClass(view.layer.class)];
    if (view.hidden) [out appendString:@" (hidden)"];
    [self describeMediaLayersIn:view.layer into:out];
#ifdef RNSC_HAS_AVKIT
    if ([view.nextResponder isKindOfClass:AVPlayerViewController.class]) {
        [out appendString:@"  <- AVPlayerViewController, captured via AVPlayerItemVideoOutput"];
    }
#endif
    [out appendString:@"\n"];
    for (UIView *subview in view.subviews) [self describeView:subview depth:depth + 1 into:out];
}

- (void)describeMediaLayersIn:(CALayer *)layer into:(NSMutableString *)out
{
    [self enumerateMediaLayersIn:layer using:^(CALayer *media, RNSCMediaLayerKind kind) {
        switch (kind) {
#if !TARGET_OS_TV
            case RNSCMediaLayerKindCameraPreview:
                [out appendString:
                    @"  <- AVCaptureVideoPreviewLayer, captured via AVCaptureVideoDataOutput"];
                return;
#endif
            case RNSCMediaLayerKindPlayer:
                [out appendString:@"  <- AVPlayerLayer, captured via AVPlayerItemVideoOutput"];
                return;
            case RNSCMediaLayerKindSampleBufferDisplay:
                [out appendString:@"  <- AVSampleBufferDisplayLayer, NOT captured yet"];
                return;
            case RNSCMediaLayerKindNone:
                return;
        }
    }];
}

@end
