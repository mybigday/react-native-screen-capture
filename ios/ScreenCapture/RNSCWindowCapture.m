//
//  RNSCWindowCapture.m
//  ScreenCapture
//

#import "RNSCWindowCapture.h"
#import "RNSCProviderRegistry.h"

static NSString *const kErrorDomain = @"com.fugood.screencapture";

/** Attaching a provider does not produce a frame instantly; give it a couple of frames. */
static const NSInteger kMaxFrameWaitAttempts = 8;
static const NSTimeInterval kFrameWaitInterval = 0.016;

/** Placed above anything the host view draws itself when we cannot reach the media layer. */
static const CGFloat kPlaceholderZPosition = 1.0e6;

@implementation RNSCWindowCapture

+ (void)captureExcludingStatusBar:(BOOL)excludeStatusBar
                       completion:(void (^)(UIImage *_Nullable, NSError *_Nullable))completion
{
    [self captureExcludingStatusBar:excludeStatusBar
                             screen:@"all"
                   markUnsupported:NO
                         completion:completion];
}

+ (void)captureExcludingStatusBar:(BOOL)excludeStatusBar
                           screen:(NSString *)screenSelector
                  markUnsupported:(BOOL)markUnsupported
                       completion:(void (^)(UIImage *_Nullable, NSError *_Nullable))completion
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self captureExcludingStatusBar:excludeStatusBar
                                     screen:screenSelector
                            markUnsupported:markUnsupported
                                 completion:completion];
        });
        return;
    }

    NSArray<NSArray<UIWindow *> *> *groups = [self windowGroupsForSelector:screenSelector];
    NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
    for (NSArray<UIWindow *> *group in groups) [allWindows addObjectsFromArray:group];
    if (allWindows.count == 0) {
        completion(nil, [NSError errorWithDomain:kErrorDomain
                                            code:404
                                        userInfo:@{NSLocalizedDescriptionKey: @"No visible window"}]);
        return;
    }

    RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
    NSArray<id<RNSCFrameProvider>> *providers = [registry attachedProvidersForWindows:allWindows];

    [self waitForFrames:providers attempt:0 then:^{
        NSError *renderError = nil;
        NSMutableArray<UIImage *> *perScreen = [NSMutableArray array];
        for (NSArray<UIWindow *> *group in groups) {
            // The status bar only exists on the main screen, so only the first group is cropped.
            BOOL crop = excludeStatusBar && group == groups.firstObject;
            // Only the providers on this screen: installing a placeholder into another
            // screen's layer tree, once per group, is wasted frame pulls and needless churn.
            NSMutableArray<id<RNSCFrameProvider>> *onScreen = [NSMutableArray array];
            for (id<RNSCFrameProvider> provider in providers) {
                UIWindow *host = provider.targetView.window;
                if (host && [group containsObject:host]) [onScreen addObject:provider];
            }
            UIImage *part = [self renderWindows:group
                                      providers:onScreen
                             excludingStatusBar:crop
                                markUnsupported:markUnsupported
                                          error:&renderError];
            if (!part) break;
            [perScreen addObject:part];
        }
        [registry scheduleIdleDetach];

        UIImage *image = perScreen.count == groups.count ? [self composeImages:perScreen] : nil;
        if (image) {
            completion(image, nil);
        } else {
            completion(nil, renderError ?: [NSError errorWithDomain:kErrorDomain
                                                               code:500
                                                           userInfo:@{
                NSLocalizedDescriptionKey: @"Render failed"
            }]);
        }
    }];
}

/**
 * The windows to capture, grouped by the screen they are on, main screen first.
 *
 * <p>`selector` is `all` (every screen, stitched), `main` (the built-in screen only), or the
 * index of a screen in {@code UIScreen.screens}.
 */
+ (NSArray<NSArray<UIWindow *> *> *)windowGroupsForSelector:(NSString *)selector
{
    NSArray<UIWindow *> *windows = [self captureWindows];

    // Grouped from the windows themselves rather than by walking UIScreen.screens: that is
    // deprecated as of iOS 16, and Apple's replacement is scene-based. Walking it would mean a
    // window whose screen it no longer lists is dropped -- silently reintroducing exactly the
    // bug this grouping exists to fix.
    NSMutableArray<UIScreen *> *order = [NSMutableArray array];
    NSMutableArray<NSMutableArray<UIWindow *> *> *lists = [NSMutableArray array];
    for (UIWindow *window in windows) {
        UIScreen *screen = window.windowScene.screen ?: window.screen ?: UIScreen.mainScreen;
        NSUInteger at = [order indexOfObjectIdenticalTo:screen];
        if (at == NSNotFound) {
            [order addObject:screen];
            [lists addObject:[NSMutableArray array]];
            at = order.count - 1;
        }
        // captureWindows already sorted by windowLevel, so each group keeps back-to-front order.
        [lists[at] addObject:window];
    }

    // Built-in screen first, so a stitched image always starts where a reader expects.
    NSUInteger mainAt = [order indexOfObjectIdenticalTo:UIScreen.mainScreen];
    if (mainAt != NSNotFound && mainAt != 0) {
        UIScreen *main = order[mainAt];
        NSMutableArray<UIWindow *> *mainList = lists[mainAt];
        [order removeObjectAtIndex:mainAt];
        [lists removeObjectAtIndex:mainAt];
        [order insertObject:main atIndex:0];
        [lists insertObject:mainList atIndex:0];
    }

    NSMutableArray<NSArray<UIWindow *> *> *groups = [NSMutableArray array];
    for (NSUInteger i = 0; i < order.count; i++) {
        UIScreen *screen = order[i];
        if ([selector isEqualToString:@"main"]) {
            if (screen != UIScreen.mainScreen) continue;
        } else if (![selector isEqualToString:@"all"]) {
            // A numeric selector means an index into UIScreen.screens, as documented.
            NSUInteger known = [UIScreen.screens indexOfObjectIdenticalTo:screen];
            NSString *label = known == NSNotFound
                ? nil : [NSString stringWithFormat:@"%lu", (unsigned long)known];
            if (!label || ![selector isEqualToString:label]) continue;
        }
        [groups addObject:lists[i]];
    }
    return groups;
}

/** Stitches one image per screen side by side, in pixels so mixed screen scales stay exact. */
+ (nullable UIImage *)composeImages:(NSArray<UIImage *> *)images
{
    if (images.count == 0) return nil;
    if (images.count == 1) return images.firstObject;

    CGFloat width = 0, height = 0;
    for (UIImage *image in images) {
        CGImageRef cg = image.CGImage;
        if (!cg) return nil;
        width += CGImageGetWidth(cg);
        height = MAX(height, (CGFloat)CGImageGetHeight(cg));
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = 1;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(width, height) format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat x = 0;
        for (UIImage *image in images) {
            CGImageRef cg = image.CGImage;
            CGFloat w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
            [image drawInRect:CGRectMake(x, 0, w, h)];
            x += w;
        }
    }];
}

/**
 * Every window this app is showing, on every screen it is showing on.
 *
 * <p>Foreground-*inactive* scenes count. A window driving an external display is not the one the
 * user is touching, so its scene is routinely inactive -- but it is exactly the content a remote
 * screenshot is asking for. Only background and unattached scenes are skipped, which keeps a
 * genuinely backgrounded app reporting "no visible window" rather than a black frame.
 */
+ (NSArray<UIWindow *> *)captureWindows
{
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive
            && scene.activationState != UISceneActivationStateForegroundInactive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden || window.alpha <= 0.01) continue;
            if (CGRectIsEmpty(window.bounds)) continue;
            [windows addObject:window];
        }
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return windows;
}

#pragma mark - Internals

/**
 * Providers that have already exhausted the frame-wait budget once.
 *
 * <p>Keyed on the provider object, not its identifier: identifiers are built from `%p`, so a
 * new AVPlayer landing on a freed one's address would otherwise inherit its verdict and never
 * be waited for again. Weak membership also means the table empties itself as providers die,
 * rather than growing for the life of the process.
 */
+ (NSHashTable<id<RNSCFrameProvider>> *)hopelessProviders
{
    static NSHashTable *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = [NSHashTable weakObjectsHashTable];
    });
    return table;
}

+ (void)waitForFrames:(NSArray<id<RNSCFrameProvider>> *)providers
              attempt:(NSInteger)attempt
                 then:(void (^)(void))next
{
    if (providers.count == 0) {
        next();
        return;
    }
    if (attempt >= kMaxFrameWaitAttempts) {
        // Remember who ran the budget out. A provider that can never deliver -- DRM content,
        // a camera session that refused an output -- would otherwise cost every capture for the
        // rest of the app's life the full wait, silently.
        for (id<RNSCFrameProvider> provider in providers) {
            if (!provider.hasFrame) [[self hopelessProviders] addObject:provider];
        }
        next();
        return;
    }
    BOOL ready = YES;
    for (id<RNSCFrameProvider> provider in providers) {
        // No early exit: -hasFrame is what pumps a player provider, so breaking here would
        // leave everything behind the first not-ready provider unpumped for the whole budget
        // and then declared hopeless off a single pump at the end.
        if (provider.hasFrame) {
            // It recovered: start blocking on it again.
            [[self hopelessProviders] removeObject:provider];
            continue;
        }
        if ([[self hopelessProviders] containsObject:provider]) continue;
        ready = NO;
    }
    if (ready) {
        next();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFrameWaitInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self waitForFrames:providers attempt:attempt + 1 then:next];
    });
}

+ (nullable UIImage *)renderWindows:(NSArray<UIWindow *> *)windows
                          providers:(NSArray<id<RNSCFrameProvider>> *)providers
                 excludingStatusBar:(BOOL)excludeStatusBar
                    markUnsupported:(BOOL)markUnsupported
                              error:(NSError **)error
{
    // Put each frame into the media component's own layer tree, so z-order, clipping and
    // transforms come out right without us computing occlusion, and so the whole thing needs
    // exactly one full-hierarchy render no matter how many media components are on screen.
    NSMutableArray<CALayer *> *placeholders = [NSMutableArray array];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (id<RNSCFrameProvider> provider in providers) {
        CALayer *placeholder = [self installPlaceholderForProvider:provider
                                                   markUnsupported:markUnsupported];
        if (placeholder) [placeholders addObject:placeholder];
    }
    if (markUnsupported) {
        // Layers we can see but cannot read on this OS. Marked through the same insertion
        // point as the placeholders, so anything drawn over them still covers the label.
        for (RNSCUnreachableLayer *item in
             [RNSCProviderRegistry.sharedRegistry unreachableLayersForWindows:windows]) {
            CALayer *marker = [self installMarkerForUnreachable:item];
            if (marker) [placeholders addObject:marker];
        }
    }
    [CATransaction commit];

    UIWindow *primary = windows.firstObject;
    CGRect bounds = primary.bounds;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = primary.screen.scale;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    // drawViewHierarchyInRect: reports failure by returning NO, not by throwing, and
    // imageWithActions: hands back an image either way. With format.opaque = YES that image is
    // solid black -- so ignoring the result turns "the system refused to snapshot" into a
    // screenshot that looks like a legitimately black screen and resolves successfully.
    __block BOOL primaryDrawn = YES;
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (UIWindow *window in windows) {
            // The context is anchored at the primary window's origin, not the screen's, so
            // draw each window where it lands *within that window* -- window.frame is in
            // screen coordinates and is only the same thing when the primary window happens
            // to start at (0,0), which it does not under iPad Split View.
            BOOL drawn =
                [window drawViewHierarchyInRect:[primary convertRect:window.bounds fromWindow:window]
                             afterScreenUpdates:YES];
            // Only the primary window is fatal. A transient overlay -- a keyboard or an alert
            // window -- refusing to snapshot should not throw away the screenshot underneath it.
            if (!drawn && window == primary) primaryDrawn = NO;
        }
    }];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer *placeholder in placeholders) [placeholder removeFromSuperlayer];
    [CATransaction commit];

    if (!primaryDrawn) {
        if (error) {
            *error = [NSError errorWithDomain:kErrorDomain code:500 userInfo:@{
                NSLocalizedDescriptionKey:
                    @"drawViewHierarchyInRect: refused to snapshot the key window. The app is "
                    @"usually not in a state the system will render -- backgrounded, mid "
                    @"transition, or covered by a secure view."
            }];
        }
        return nil;
    }

    if (excludeStatusBar && image) {
        image = [self cropStatusBarFromImage:image window:primary];
    }
    return image;
}

/**
 * Builds the label drawn over a region this build cannot capture.
 *
 * It goes in as a layer at the same insertion point a placeholder would, so whatever sits above
 * the media component on screen covers the label too -- occlusion, clipping and transforms stay
 * the platform's job rather than arithmetic here.
 */
+ (CALayer *)markerLayerWithReason:(NSString *)reason rect:(CGRect)rect
{
    CALayer *marker = [CALayer layer];
    marker.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    marker.borderColor = [UIColor colorWithRed:1 green:0.23 blue:0.19 alpha:0.9].CGColor;
    marker.borderWidth = 2;
    marker.masksToBounds = YES;
    marker.bounds = CGRectMake(0, 0, CGRectGetWidth(rect), CGRectGetHeight(rect));
    marker.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));

    CGFloat fontSize = MIN(MAX(CGRectGetHeight(rect) / 12.0, 11.0), 22.0);
    CATextLayer *text = [CATextLayer layer];
    text.string = reason;
    text.wrapped = YES;
    text.alignmentMode = kCAAlignmentCenter;
    text.fontSize = fontSize;
    text.foregroundColor = UIColor.whiteColor.CGColor;
    text.contentsScale = UIScreen.mainScreen.scale;
    // Three lines' worth, centred: enough for the longest reason without measuring.
    CGFloat textHeight = MIN(fontSize * 3.6, CGRectGetHeight(rect));
    text.frame = CGRectMake(6,
                            (CGRectGetHeight(rect) - textHeight) / 2.0,
                            MAX(CGRectGetWidth(rect) - 12, 1),
                            textHeight);
    [marker addSublayer:text];
    return marker;
}

/** Puts a marker over a layer we recognise but cannot read on this OS. */
+ (nullable CALayer *)installMarkerForUnreachable:(RNSCUnreachableLayer *)item
{
    UIView *target = item.targetView;
    CALayer *media = item.mediaLayer;
    if (!target || !media) return nil;

    CALayer *host = media.superlayer ?: target.layer;
    CGRect rect = media.superlayer ? media.frame : target.bounds;
    if (CGRectIsEmpty(rect)) return nil;

    CALayer *marker = [self markerLayerWithReason:item.reason rect:rect];
    if (media.superlayer) {
        [host insertSublayer:marker above:media];
    } else {
        marker.zPosition = kPlaceholderZPosition;
        [host addSublayer:marker];
    }
    return marker;
}

+ (nullable CALayer *)installPlaceholderForProvider:(id<RNSCFrameProvider>)provider
                                    markUnsupported:(BOOL)markUnsupported
{
    UIView *target = provider.targetView;
    if (!target) return nil;

    CGImageRef frame = [provider newFrameImage];

    CALayer *media = provider.mediaLayer;
    CALayer *host = media.superlayer ?: target.layer;
    CGRect rect = media ? media.frame : target.bounds;
    if (CGRectIsEmpty(rect)) {
        if (frame) CGImageRelease(frame);
        return nil;
    }

    if (!frame) {
        // Attached, but the pipeline yielded nothing -- DRM-protected video, or a capture
        // session that refused an output. Without marking, this region simply renders black.
        if (!markUnsupported) return nil;
        CALayer *marker =
            [self markerLayerWithReason:@"No frame available (protected or unavailable)"
                                   rect:rect];
        if (media && media.superlayer) {
            [host insertSublayer:marker above:media];
        } else {
            marker.zPosition = kPlaceholderZPosition;
            [host addSublayer:marker];
        }
        return marker;
    }

    CALayer *placeholder = [CALayer layer];
    placeholder.contents = (__bridge id)frame;
    placeholder.contentsGravity = provider.contentsGravity;
    placeholder.masksToBounds = YES;
    // Set bounds/position rather than frame: frame is undefined once a transform is applied.
    // A quarter turn has to swap the layer's bounds as well: rotating a rect-shaped layer about
    // its centre leaves it overhanging the media rect with the aspect transposed. Only rotations
    // that are multiples of 90 are produced here, so a near-zero m11 identifies the odd ones.
    CATransform3D transform = provider.contentsTransform;
    BOOL quarterTurn = fabs(transform.m11) < 0.5;
    CGFloat boundsWidth = quarterTurn ? CGRectGetHeight(rect) : CGRectGetWidth(rect);
    CGFloat boundsHeight = quarterTurn ? CGRectGetWidth(rect) : CGRectGetHeight(rect);
    placeholder.bounds = CGRectMake(0, 0, boundsWidth, boundsHeight);
    placeholder.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    placeholder.transform = transform;
    CGImageRelease(frame);

    if (media && media.superlayer) {
        [host insertSublayer:placeholder above:media];
    } else {
        placeholder.zPosition = kPlaceholderZPosition;
        [host addSublayer:placeholder];
    }
    return placeholder;
}

+ (UIImage *)cropStatusBarFromImage:(UIImage *)image window:(UIWindow *)window
{
    CGFloat height = 0;
#if TARGET_OS_IOS
    height = window.windowScene.statusBarManager.statusBarFrame.size.height;
#endif
    if (height <= 0 || height >= image.size.height) return image;

    CGFloat scale = image.scale;
    CGRect crop = CGRectMake(0,
                             height * scale,
                             image.size.width * scale,
                             (image.size.height - height) * scale);
    CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, crop);
    if (!cropped) return image;
    UIImage *result = [UIImage imageWithCGImage:cropped
                                          scale:scale
                                    orientation:image.imageOrientation];
    CGImageRelease(cropped);
    return result;
}

@end
