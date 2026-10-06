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

static NSMutableArray *RNSCPendingOperations;
static BOOL RNSCOperationRunning;

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

    [self performSerially:^(dispatch_block_t done) {
        __block BOOL delivered = NO;
        [self captureNowExcludingStatusBar:excludeStatusBar
                                    screen:screenSelector
                           markUnsupported:markUnsupported
                                completion:^(UIImage *image, NSError *error) {
                                    if (delivered)
                                        return;
                                    delivered = YES;
                                    @try
                                    {
                                        completion(image, error);
                                    }
                                    @finally
                                    {
                                        done();
                                    }
                                }];
    }];
}

+ (void)performSerially:(void (^)(dispatch_block_t done))operation
{
    if (!NSThread.isMainThread)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self performSerially:operation];
        });
        return;
    }
    if (!RNSCPendingOperations)
        RNSCPendingOperations = [NSMutableArray array];
    [RNSCPendingOperations addObject:[operation copy]];
    if (RNSCOperationRunning)
        return;
    RNSCOperationRunning = YES;
    [self drainOperations:RNSCPendingOperations];
}

+ (void)drainOperations:(NSMutableArray *)pending
{
    void (^operation)(dispatch_block_t) = pending.firstObject;
    [pending removeObjectAtIndex:0];
    __block BOOL completed = NO;
    operation(^{
        if (completed)
            return;
        completed = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (pending.count)
                [self drainOperations:pending];
            else
                [self serialQueueDidDrain];
        });
    });
}

+ (void)serialQueueDidDrain
{
    RNSCOperationRunning = NO;
}

+ (void)captureNowExcludingStatusBar:(BOOL)excludeStatusBar
                              screen:(NSString *)screenSelector
                     markUnsupported:(BOOL)markUnsupported
                          completion:(void (^)(UIImage *, NSError *))completion
{
    @try
    {
        NSArray<NSArray<UIWindow *> *> *groups = [self windowGroupsForSelector:screenSelector];
        NSMutableArray<UIWindow *> *allWindows = [NSMutableArray array];
        for (NSArray<UIWindow *> *group in groups)
            [allWindows addObjectsFromArray:group];
        if (allWindows.count == 0)
        {
            completion(
                nil, [NSError errorWithDomain:kErrorDomain
                                         code:404
                                     userInfo:@{NSLocalizedDescriptionKey : @"No visible window"}]);
            return;
        }

        RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
        NSArray<id<RNSCFrameProvider>> *providers =
            [registry attachedProvidersForWindows:allWindows];

        NSMutableArray<NSValue *> *bounds = [NSMutableArray array];
        NSMutableArray *screens = [NSMutableArray array];
        double totalPixels = 0;
        for (UIWindow *window in allWindows)
        {
            [bounds addObject:[NSValue valueWithCGRect:window.bounds]];
            [screens addObject:window.windowScene.screen ?: window.screen];
        }
        for (NSArray<UIWindow *> *group in groups)
        {
            UIWindow *primary = group.firstObject;
            double width = primary.bounds.size.width * primary.screen.scale;
            double height = primary.bounds.size.height * primary.screen.scale;
            if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0)
            {
                [NSException raise:@"CaptureDimensions" format:@"Invalid window dimensions"];
            }
            totalPixels += width * height;
        }
        if (totalPixels > 64000000)
            [NSException raise:@"CaptureDimensions" format:@"Capture exceeds 64 megapixels"];

        [self waitForFrames:providers
                    attempt:0
                       then:^(NSError *frameError) {
                           if (frameError)
                           {
                               [registry scheduleIdleDetach];
                               completion(nil, frameError);
                               return;
                           }
                           @try
                           {
                               NSMutableArray<NSNumber *> *generations = [NSMutableArray array];
                               for (id<RNSCFrameProvider> provider in providers) {
                                   [generations addObject:@([provider respondsToSelector:@selector(attachmentGeneration)] ? provider.attachmentGeneration : 0)];
                               }
                               NSArray *currentGroups =
                                   [self windowGroupsForSelector:screenSelector];
                               BOOL unchanged = [groups isEqual:currentGroups];
                               for (NSUInteger i = 0; i < allWindows.count; i++)
                               {
                                   unchanged = unchanged &&
                                               CGRectEqualToRect(allWindows[i].bounds,
                                                                 bounds[i].CGRectValue) &&
                                               (allWindows[i].windowScene.screen
                                                    ?: allWindows[i].screen) == screens[i];
                               }
                               for (id<RNSCFrameProvider> provider in providers)
                                   unchanged = unchanged && provider.isAlive;
                               if (unchanged)
                               {
                                   // Discovery can change inside identical windows (remount, new
                                   // media layer/item). At the end of the wait it is safe to prune;
                                   // retry instead of drawing stale providers.
                                   NSArray *currentProviders =
                                       [registry attachedProvidersForWindows:allWindows];
                                   unchanged = [providers isEqual:currentProviders];
                                   for (NSUInteger i = 0; i < providers.count; i++) {
                                       NSUInteger generation = [providers[i] respondsToSelector:@selector(attachmentGeneration)] ? providers[i].attachmentGeneration : 0;
                                       unchanged = unchanged && generation == generations[i].unsignedIntegerValue;
                                   }
                               }
                               if (!unchanged)
                               {
                                   [registry scheduleIdleDetach];
                                   completion(nil,
                                              [NSError
                                                  errorWithDomain:kErrorDomain
                                                             code:409
                                                         userInfo:@{
                                                             NSLocalizedDescriptionKey :
                                                                 @"Windows changed while waiting "
                                                                 @"for a media frame; retry capture"
                                                         }]);
                                   return;
                               }
                               NSError *renderError = nil;
                               NSMutableArray<UIImage *> *perScreen = [NSMutableArray array];
                               for (NSArray<UIWindow *> *group in groups)
                               {
                                   // The status bar only exists on the main screen, so only the
                                   // first group is cropped.
                                   BOOL crop = excludeStatusBar && group == groups.firstObject;
                                   // Only the providers on this screen: installing a placeholder
                                   // into another screen's layer tree, once per group, is wasted
                                   // frame pulls and needless churn.
                                   NSMutableArray<id<RNSCFrameProvider>> *onScreen =
                                       [NSMutableArray array];
                                   for (id<RNSCFrameProvider> provider in providers)
                                   {
                                       UIWindow *host = provider.targetView.window;
                                       if (host && [group containsObject:host])
                                           [onScreen addObject:provider];
                                   }
                                   UIImage *part = [self renderWindows:group
                                                             providers:onScreen
                                                    excludingStatusBar:crop
                                                       markUnsupported:markUnsupported
                                                                 error:&renderError];
                                   if (!part)
                                       break;
                                   [perScreen addObject:part];
                               }
                               [registry scheduleIdleDetach];

                               UIImage *image = perScreen.count == groups.count
                                                    ? [self composeImages:perScreen]
                                                    : nil;
                               if (image)
                               {
                                   completion(image, nil);
                               }
                               else
                               {
                                   completion(nil,
                                              renderError
                                                  ?: [NSError errorWithDomain:kErrorDomain
                                                                         code:500
                                                                     userInfo:@{
                                                                         NSLocalizedDescriptionKey :
                                                                             @"Render failed"
                                                                     }]);
                               }
                           }
                           @catch (NSException *exception)
                           {
                               [registry scheduleIdleDetach];
                               completion(nil, [NSError errorWithDomain:kErrorDomain
                                                                   code:500
                                                               userInfo:@{
                                                                   NSLocalizedDescriptionKey :
                                                                           exception.reason
                                                                       ?: @"Render failed"
                                                               }]);
                           }
                       }];
    }
    @catch (NSException *exception)
    {
        [RNSCProviderRegistry.sharedRegistry scheduleIdleDetach];
        completion(nil, [NSError errorWithDomain:kErrorDomain
                                            code:500
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : exception.reason
                                                ?: @"Capture failed"
                                        }]);
    }
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

    if (!isfinite(width * height) || width * height > 64000000)
    {
        [NSException raise:@"CaptureDimensions" format:@"Stitched capture exceeds 64 megapixels"];
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
                 then:(void (^)(NSError *_Nullable))next
{
    if (providers.count == 0)
    {
        next(nil);
        return;
    }
    BOOL ready = YES;
    NSError *failure = nil;
    @try
    {
        if (attempt >= kMaxFrameWaitAttempts)
        {
            for (id<RNSCFrameProvider> provider in providers)
            {
                if (!provider.hasFrame)
                    [[self hopelessProviders] addObject:provider];
            }
        }
        else
        {
            // Pump every provider, including everything behind a provider without a frame.
            for (id<RNSCFrameProvider> provider in providers)
            {
                if (provider.hasFrame)
                    [[self hopelessProviders] removeObject:provider];
                else if (![[self hopelessProviders] containsObject:provider])
                    ready = NO;
            }
        }
    }
    @catch (NSException *exception)
    {
        failure = [NSError
            errorWithDomain:kErrorDomain
                       code:500
                   userInfo:@{
                       NSLocalizedDescriptionKey : exception.reason ?: @"Frame provider failed"
                   }];
    }
    // Operational exceptions and callback exceptions have separate ownership.
    if (failure || ready || attempt >= kMaxFrameWaitAttempts)
    {
        next(failure);
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
    UIImage *image = nil;
    BOOL primaryDrawn = YES;
    UIWindow *primary = windows.firstObject;
    @try
    {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        @try
        {
            for (id<RNSCFrameProvider> provider in providers)
            {
                CALayer *placeholder = [self installPlaceholderForProvider:provider
                                                           markUnsupported:markUnsupported];
                if (placeholder)
                    [placeholders addObject:placeholder];
            }
            if (markUnsupported)
            {
                // Layers we can see but cannot read on this OS. Marked through the same insertion
                // point as the placeholders, so anything drawn over them still covers the label.
                for (RNSCUnreachableLayer *item in
                     [RNSCProviderRegistry.sharedRegistry unreachableLayersForWindows:windows])
                {
                    CALayer *marker = [self installMarkerForUnreachable:item];
                    if (marker) [placeholders addObject:marker];
        }
    }
        }
        @finally
        {
            [CATransaction commit];
        }

    CGRect bounds = primary.bounds;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = primary.screen.scale;

    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:bounds.size format:format];
    // Transparent system overlays must not flatten the already-drawn primary window to black.
    // Preserve the primary draw failure signal independently of renderer opacity.
    __block BOOL drawSucceeded = YES;
    image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (UIWindow *window in windows)
        {
            // The context is anchored at the primary window's origin, not the screen's, so
            // draw each window where it lands *within that window* -- window.frame is in
            // screen coordinates and is only the same thing when the primary window happens
            // to start at (0,0), which it does not under iPad Split View.
            BOOL drawn =
                [window drawViewHierarchyInRect:[primary convertRect:window.bounds fromWindow:window]
                             afterScreenUpdates:YES];
            // Only the primary window is fatal. A transient overlay -- a keyboard or an alert
            // window -- refusing to snapshot should not throw away the screenshot underneath it.
            if (!drawn && window == primary)
                drawSucceeded = NO;
        }
    }];
    primaryDrawn = drawSucceeded;
    }
    @finally
    {

        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (CALayer *placeholder in placeholders)
            [placeholder removeFromSuperlayer];
        [CATransaction commit];
    }

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
    CGRect rect = media.superlayer ? media.bounds : target.bounds;
    if (CGRectIsEmpty(rect)) return nil;

    CALayer *marker = [self markerLayerWithReason:item.reason rect:rect];
    if (media.superlayer)
        [self copyGeometry:media to:marker];
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

    CALayer *media = provider.mediaLayer;
    BOOL sibling = media.superlayer != nil;
    CALayer *host = sibling ? media.superlayer : target.layer;
    CGRect rect = sibling ? media.bounds : target.bounds;
    if (CGRectIsEmpty(rect) || (media && (media.hidden || media.opacity <= 0.01)))
        return nil;
    CGImageRef frame = [provider newFrameImage];
    CALayer *container = nil;
    @try
    {
        if (!frame)
        {
            if (!markUnsupported)
                return nil;
            container = [self markerLayerWithReason:@"No frame available (protected or unavailable)"
                                               rect:rect];
        }
        else
        {
            container = [CALayer layer];
            container.bounds = rect;
            container.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
            container.masksToBounds = YES;
            CALayer *pixels = [CALayer layer];
            pixels.contents = (__bridge id)frame;
            pixels.contentsGravity = provider.contentsGravity;
            CATransform3D transform = provider.contentsTransform;
            BOOL quarterTurn = fabs(transform.m11) < 0.5;
            pixels.bounds = CGRectMake(0, 0, quarterTurn ? rect.size.height : rect.size.width,
                                       quarterTurn ? rect.size.width : rect.size.height);
            pixels.position = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
            pixels.transform = transform;
            [container addSublayer:pixels];
        }
        if (sibling)
        {
            [self copyGeometry:media to:container];
            [host insertSublayer:container above:media];
        }
        else
        {
            container.zPosition = kPlaceholderZPosition;
            [host addSublayer:container];
        }
        return container;
    }
    @finally
    {
        if (frame)
            CGImageRelease(frame);
    }
}

+ (void)copyGeometry:(CALayer *)media to:(CALayer *)container
{
    container.bounds = media.bounds;
    container.anchorPoint = media.anchorPoint;
    container.anchorPointZ = media.anchorPointZ;
    container.position = media.position;
    container.transform = media.transform;
    container.zPosition = media.zPosition;
    container.opacity = media.opacity;
    container.hidden = media.hidden;
    if (media.masksToBounds)
    {
        container.cornerRadius = media.cornerRadius;
        container.maskedCorners = media.maskedCorners;
        container.cornerCurve = media.cornerCurve;
    }
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
