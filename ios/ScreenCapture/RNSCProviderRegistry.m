//
//  RNSCProviderRegistry.m
//  ScreenCapture
//

#import "RNSCProviderRegistry.h"
#import "RNSCCameraFrameProvider.h"
#import "RNSCPlayerFrameProvider.h"
#import "RNSCSampleBufferFrameProvider.h"

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
    RNSCMediaLayerKindMetal,
};

@implementation RNSCUnreachableLayer {
    __weak UIView *_targetView;
    __weak CALayer *_mediaLayer;
}
@synthesize reason = _reason;

- (instancetype)initWithView:(UIView *)view layer:(CALayer *)layer reason:(NSString *)reason
{
    self = [super init];
    if (self) {
        _targetView = view;
        _mediaLayer = layer;
        _reason = [reason copy];
    }
    return self;
}

- (UIView *)targetView { return _targetView; }
- (CALayer *)mediaLayer { return _mediaLayer; }

@end

@implementation RNSCProviderRegistry {
    NSMutableDictionary<NSString *, id<RNSCFrameProvider>> *_providers;
    NSTimer *_idleTimer;
#if !TARGET_OS_TV
    NSMapTable<NSString *, RNSCCameraFrameProvider *> *_cameraSources;
#endif
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
#if !TARGET_OS_TV
        _cameraSources = [NSMapTable strongToWeakObjectsMapTable];
#endif
    }
    return self;
}

#pragma mark - Public

- (NSArray<id<RNSCFrameProvider>> *)attachedProvidersForWindows:(NSArray<UIWindow *> *)windows
{
    [_idleTimer invalidate];
    _idleTimer = nil;

#if !TARGET_OS_TV
    for (NSString *key in _cameraSources.keyEnumerator.allObjects)
    {
        if (![_cameraSources objectForKey:key])
            [_cameraSources removeObjectForKey:key];
    }
#endif
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
                                                       @try
                                                       {
                                                           [weakSelf detachAll];
                                                       }
                                                       @catch (NSException *exception)
                                                       {
                                                           // Preserve ownership for a later cleanup retry.
                                                       }
                                                   }];
}

- (void)detachAll
{
    [_idleTimer invalidate];
    _idleTimer = nil;
    NSException *failure = nil;
    for (NSString *key in _providers.allKeys)
    {
        @try
        {
            [_providers[key] detach];
            [_providers removeObjectForKey:key];
        }
        @catch (NSException *exception)
        {
            if (!failure)
                failure = exception;
        }
    }
#if !TARGET_OS_TV
    for (NSString *key in _cameraSources.keyEnumerator.allObjects)
    {
        if (![_cameraSources objectForKey:key])
            [_cameraSources removeObjectForKey:key];
    }
#endif
    if (failure)
        @throw failure;
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
        if (controller.view == view && controller.player &&
            ![self view:view containsPlayerLayerFor:controller.player])
        {
            [self addProviderWithIdentifier:[RNSCPlayerFrameProvider
                                                identifierForPlayer:controller.player
                                                               view:view
                                                              layer:nil]
                                       into:found
                                    builder:^id<RNSCFrameProvider> {
                                        return [[RNSCPlayerFrameProvider alloc]
                                            initWithPlayer:controller.player
                                                targetView:view
                                                mediaLayer:nil
                                                   gravity:RNSCContentsGravityForVideoGravity(
                                                               controller.videoGravity)];
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
    } else if ([layer isKindOfClass:AVSampleBufferDisplayLayer.class]) {
        kind = RNSCMediaLayerKindSampleBufferDisplay;
    } else if ([layer isKindOfClass:(Class)NSClassFromString(@"CAMetalLayer")]) {
        kind = RNSCMediaLayerKindMetal;
    }
    if (kind != RNSCMediaLayerKindNone) block(layer, kind);

    for (CALayer *sublayer in layer.sublayers) {
        // Subviews own their layers; discoverInView: will reach those on its own.
        if ([sublayer.delegate isKindOfClass:UIView.class]) continue;
        [self enumerateMediaLayersIn:sublayer using:block];
    }
}

- (BOOL)view:(UIView *)view containsPlayerLayerFor:(AVPlayer *)player
{
    if (view.hidden || view.alpha <= 0.01)
        return NO;
    __block BOOL found = NO;
    [self enumerateMediaLayersIn:view.layer
                           using:^(CALayer *media, RNSCMediaLayerKind kind) {
                               if (kind == RNSCMediaLayerKindPlayer &&
                                   ((AVPlayerLayer *)media).player == player)
                                   found = YES;
                           }];
    if (found)
        return YES;
    for (UIView *child in view.subviews)
        if ([self view:child containsPlayerLayerFor:player])
            return YES;
    return NO;
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
                NSString *identifier = [NSString
                    stringWithFormat:@"camera:%p:view:%p:layer:%p", preview.session, view, preview];
                NSString *sourceKey = [RNSCCameraFrameProvider sourceIdentifierForPreview:preview];
                RNSCCameraFrameProvider *source = [self->_cameraSources objectForKey:sourceKey];
                if (!source || ![source matchesPreview:preview])
                {
                    source = [[RNSCCameraFrameProvider alloc] initWithPreviewLayer:preview
                                                                        targetView:view];
                    if (!source) return;
                    // Construction may observe a newer connection than discovery did.
                    [self->_cameraSources setObject:source forKey:source.identifier];
                }
                [self addProviderWithIdentifier:identifier
                                           into:found
                                        builder:^id<RNSCFrameProvider> {
                                            return [[RNSCCameraPresentation alloc]
                                                initWithSource:source
                                                       preview:preview
                                                          view:view];
                                        }];
                return;
            }
#endif
            case RNSCMediaLayerKindPlayer: {
                AVPlayerLayer *playerLayer = (AVPlayerLayer *)media;
                if (!playerLayer.player) return;
                NSString *identifier =
                    [RNSCPlayerFrameProvider identifierForPlayer:playerLayer.player
                                                            view:view
                                                           layer:playerLayer];
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
            case RNSCMediaLayerKindSampleBufferDisplay: {
                AVSampleBufferDisplayLayer *display = (AVSampleBufferDisplayLayer *)media;
                NSString *identifier =
                    [NSString stringWithFormat:@"samplebuffer:%p:view:%p", display, view];
                [self addProviderWithIdentifier:identifier
                                           into:found
                                        builder:^id<RNSCFrameProvider> {
                    return [[RNSCSampleBufferFrameProvider alloc] initWithDisplayLayer:display
                                                                            targetView:view];
                }];
                return;
            }
            default:
                // Recognised by the dump, not capturable.
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

- (NSArray<RNSCUnreachableLayer *> *)unreachableLayersForWindows:(NSArray<UIWindow *> *)windows
{
    NSMutableArray<RNSCUnreachableLayer *> *found = [NSMutableArray array];
    for (UIWindow *window in windows) {
        [self collectUnreachableInView:window into:found];
    }
    return found;
}

- (void)collectUnreachableInView:(UIView *)view
                            into:(NSMutableArray<RNSCUnreachableLayer *> *)found
{
    if (view.hidden || view.alpha <= 0.01) return;
    [self enumerateMediaLayersIn:view.layer using:^(CALayer *media, RNSCMediaLayerKind kind) {
        if (kind != RNSCMediaLayerKindSampleBufferDisplay) return;
        if (@available(iOS 17.4, tvOS 17.4, *)) return;   // a provider covers it
        [found addObject:[[RNSCUnreachableLayer alloc]
            initWithView:view
                   layer:media
                  reason:@"AVSampleBufferDisplayLayer needs iOS 17.4"]];
    }];
    for (UIView *subview in view.subviews) [self collectUnreachableInView:subview into:found];
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
                if (@available(iOS 17.4, tvOS 17.4, *)) {
                    [out appendString:
                        @"  <- AVSampleBufferDisplayLayer, captured via copyDisplayedPixelBuffer"];
                } else {
                    [out appendString:
                        @"  <- AVSampleBufferDisplayLayer, NOT captured (needs iOS 17.4)"];
                }
                return;
            case RNSCMediaLayerKindMetal:
                // Hierarchy drawing captures in-process Metal content; no provider is needed.
                [out appendString:
                    @"  <- CAMetalLayer, captured directly by the hierarchy draw"];
                return;
            case RNSCMediaLayerKindNone:
                return;
        }
    }];
}

@end
