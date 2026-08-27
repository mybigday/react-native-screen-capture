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

- (void)inspectLayer:(CALayer *)layer
             forView:(UIView *)view
                into:(NSMutableArray<id<RNSCFrameProvider>> *)found
{
    if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class]) {
        AVCaptureVideoPreviewLayer *preview = (AVCaptureVideoPreviewLayer *)layer;
        if (preview.session) {
            [self addProviderWithIdentifier:[NSString stringWithFormat:@"camera:%p", preview.session]
                                       into:found
                                    builder:^id<RNSCFrameProvider> {
                return [[RNSCCameraFrameProvider alloc] initWithPreviewLayer:preview targetView:view];
            }];
        }
    } else if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayerLayer *playerLayer = (AVPlayerLayer *)layer;
        if (playerLayer.player) {
            [self addProviderWithIdentifier:[NSString stringWithFormat:@"player:%p", playerLayer.player]
                                       into:found
                                    builder:^id<RNSCFrameProvider> {
                return [[RNSCPlayerFrameProvider alloc]
                    initWithPlayer:playerLayer.player
                        targetView:view
                        mediaLayer:playerLayer
                           gravity:RNSCContentsGravityForVideoGravity(playerLayer.videoGravity)];
            }];
        }
    }

    for (CALayer *sublayer in layer.sublayers) {
        // Subviews own their layers; discoverInView: will reach those on its own.
        if ([sublayer.delegate isKindOfClass:UIView.class]) continue;
        [self inspectLayer:sublayer forView:view into:found];
    }
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
    if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class]) {
        [out appendString:@"  <- AVCaptureVideoPreviewLayer, captured via AVCaptureVideoDataOutput"];
    } else if ([layer isKindOfClass:AVPlayerLayer.class]) {
        [out appendString:@"  <- AVPlayerLayer, captured via AVPlayerItemVideoOutput"];
    } else if ([NSStringFromClass(layer.class) containsString:@"AVSampleBufferDisplayLayer"]) {
        [out appendString:@"  <- AVSampleBufferDisplayLayer, NOT captured yet"];
    }
    for (CALayer *sublayer in layer.sublayers) {
        if ([sublayer.delegate isKindOfClass:UIView.class]) continue;
        [self describeMediaLayersIn:sublayer into:out];
    }
}

@end
