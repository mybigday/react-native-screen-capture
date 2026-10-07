//
//  ScreenCapture.mm
//  ScreenCapture
//

#import "ScreenCapture.h"
#import "RNSCFileStore.h"
#import "RNSCProviderRegistry.h"
#import "RNSCWindowCapture.h"
#include <limits.h>
#import <math.h>

#import <UIKit/UIKit.h>

static BOOL RNSCCaptureInFlight;

// Validate the actual rounded/clamped allocation, not its fractional precursor.
static BOOL RNSCScaledPixelDimensions(double width, double height, double scale,
                                     double *pixelWidth, double *pixelHeight)
{
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 ||
        !isfinite(scale) || scale <= 0) return NO;
    width = fmax(1.0, round(width * scale));
    height = fmax(1.0, round(height * scale));
    if (!isfinite(width) || !isfinite(height) || width > INT_MAX || height > INT_MAX ||
        width * height > 64000000) return NO;
    *pixelWidth = width;
    *pixelHeight = height;
    return YES;
}

static NSError *RNSCExceptionError(NSException *exception)
{
    return [NSError
        errorWithDomain:@"com.fugood.screencapture"
                   code:500
               userInfo:@{NSLocalizedDescriptionKey : exception.reason ?: @"Capture failed"}];
}

static NSString *const kEventScreenshot = @"ScreenCapture";
static NSString *const kErrorCapture = @"E_CAPTURE";
static NSString *const kErrorUnsupported = @"E_UNSUPPORTED";

@implementation ScreenCapture {
    BOOL _captureInFlight;
    BOOL _invalidated;
    BOOL _hasListeners;
    BOOL _observingScreenshots;
}

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup
{
    return NO;
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[kEventScreenshot];
}

- (void)startObserving
{
    _hasListeners = YES;
}

- (void)stopObserving
{
    _hasListeners = NO;
}

- (void)invalidate
{
    @synchronized(self)
    {
        _invalidated = YES;
    }
    [self stopScreenshotObserver];
    // The registry is main-thread only: its timer lives on the main run loop and its provider
    // map is mutated during discovery. invalidate() runs on the module's queue.
    [RNSCWindowCapture performSerially:^(dispatch_block_t done) {
        @try
        {
            [RNSCProviderRegistry.sharedRegistry detachAll];
        }
        @catch (NSException *exception)
        { /* Registry retains failed cleanup ownership. */
        }
        @finally
        {
            done();
        }
    }];
    [super invalidate];
}

#pragma mark - capture

RCT_EXPORT_METHOD(capture:(NSDictionary *)options
                  resolve:(RCTPromiseResolveBlock)resolve
                   reject:(RCTPromiseRejectBlock)reject)
{
    NSString *mode = options[@"mode"] ?: @"view";
    if (![mode isEqualToString:@"view"]) {
        // `accessibility` is an Android-only mode. iOS has no equivalent: there is no public API
        // that lets an app capture outside its own windows.
        reject(kErrorUnsupported,
               [NSString stringWithFormat:@"Capture mode '%@' is not available on iOS", mode],
               nil);
        return;
    }

    BOOL excludeStatusBar = [options[@"excludeStatusBar"] boolValue];
    NSString *extension = options[@"extension"] ?: @"png";
    CGFloat quality = options[@"quality"] ? [options[@"quality"] doubleValue] : 100.0;
    CGFloat scale = options[@"scale"] ? [options[@"scale"] doubleValue] : 1.0;
    BOOL includeBase64 = [options[@"includeBase64"] boolValue];
    NSString *screen = options[@"screen"] ?: @"all";
    BOOL markUnsupported = [options[@"markUnsupported"] boolValue];

    if (!isfinite(scale) || scale <= 0 || !isfinite(quality))
    {
        reject(kErrorCapture, @"scale must be finite and positive; quality must be finite", nil);
        return;
    }
    NSString *admissionError = nil;
    @synchronized(ScreenCapture.class)
    {
        if ([self isInvalidated])
            admissionError = @"Module is shutting down";
        else if (RNSCCaptureInFlight)
            admissionError = @"A capture is already in flight";
        else
        {
            _captureInFlight = YES;
            RNSCCaptureInFlight = YES;
        }
    }
    if (admissionError)
    {
        reject([admissionError isEqual:@"A capture is already in flight"] ? @"E_CAPTURE_BUSY"
                                                                          : kErrorCapture,
               admissionError, nil);
        return;
    }

    [RNSCWindowCapture
        captureExcludingStatusBar:excludeStatusBar
                           screen:screen
                  markUnsupported:markUnsupported
                       completion:^(UIImage *image, NSError *error) {
                           if (!image || [self isInvalidated])
                           {
                               [self finishCapture];
                               reject(kErrorCapture,
                                      [self isInvalidated]
                                          ? @"Module is shutting down"
                                          : (error.localizedDescription ?: @"Capture failed"),
                                      error);
                               return;
                           }
                           // Encode off the main thread.
                           dispatch_async(RNSCFileQueue(), ^{
                               [self encodeImage:image
                                       extension:extension
                                         quality:quality
                                           scale:scale
                                   includeBase64:includeBase64
                                         resolve:resolve
                                          reject:reject];
                           });
                       }];
}

- (void)encodeImage:(UIImage *)image
          extension:(NSString *)extension
            quality:(CGFloat)quality
              scale:(CGFloat)scale
      includeBase64:(BOOL)includeBase64
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject
{
    NSMutableDictionary *result = nil;
    NSError *failure = nil;
    NSString *path = nil;
    @autoreleasepool
    {
        @try {
            if ([self isInvalidated])
                [NSException raise:@"CaptureCancelled" format:@"Module is shutting down"];
            UIImage *output = scale != 1.0 ? [self scaleImage:image by:scale] : image;
            BOOL isJPEG = [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"];
            NSData *data = isJPEG ? UIImageJPEGRepresentation(output, MAX(0.0, MIN(1.0, quality / 100.0)))
                                  : UIImagePNGRepresentation(output);
            if (!data.length)
            {
                failure = [NSError
                    errorWithDomain:@"com.fugood.screencapture"
                               code:500
                           userInfo:@{NSLocalizedDescriptionKey : @"Could not encode the image"}];
            }
            else
            {
                // Build metadata before publication to avoid orphan files.
                result = [NSMutableDictionary dictionary];
                CGImageRef cgImage = output.CGImage;
                result[@"width"] =
                    @(cgImage ? CGImageGetWidth(cgImage) : lround(output.size.width * output.scale));
                result[@"height"] =
                    @(cgImage ? CGImageGetHeight(cgImage) : lround(output.size.height * output.scale));
                if (includeBase64)
                    result[@"base64"] = [data base64EncodedStringWithOptions:0];
                path = [[RNSCFileStore defaultStore] writeData:data
                                                     extension:isJPEG ? @"jpg" : @"png"
                                                         error:&failure];
                if (path)
                    result[@"uri"] = [NSURL fileURLWithPath:path].absoluteString;
                else
                    result = nil;
                if ([self isInvalidated])
                    [NSException raise:@"CaptureCancelled" format:@"Module is shutting down"];
            }
        } @catch (NSException *exception) {
            result = nil;
            failure = [NSError
                errorWithDomain:@"com.fugood.screencapture"
                           code:500
                       userInfo:@{NSLocalizedDescriptionKey : exception.reason ?: @"Capture failed"}];
        }
        @try
        {
            if (!result && path)
            {
                NSError *cleanupError = nil;
                @try
                {
                    [[RNSCFileStore defaultStore] releaseURI:[NSURL fileURLWithPath:path].absoluteString
                                                       error:&cleanupError];
                }
                @catch (NSException *exception)
                {
                    cleanupError = RNSCExceptionError(exception);
                }
                if (cleanupError)
                    failure =
                        [NSError errorWithDomain:failure.domain
                                            code:failure.code
                                        userInfo:@{
                                            NSLocalizedDescriptionKey : failure.localizedDescription,
                                            NSUnderlyingErrorKey : cleanupError
                                        }];
            }
        }
        @finally
        {
            [self finishCapture];
        }
    }
    // Drain temporaries before settlement can throw.
    if (result)
        resolve(result);
    else
        reject(kErrorCapture, failure.localizedDescription ?: @"Capture failed", failure);
}

- (BOOL)isInvalidated
{
    @synchronized(self)
    {
        return _invalidated;
    }
}

- (void)finishCapture
{
    @synchronized(ScreenCapture.class)
    {
        if (_captureInFlight)
            RNSCCaptureInFlight = NO;
        _captureInFlight = NO;
    }
}

- (UIImage *)scaleImage:(UIImage *)image by:(CGFloat)scale
{
    double width = 0, height = 0;
    if (!RNSCScaledPixelDimensions(image.size.width * image.scale,
                                   image.size.height * image.scale, scale, &width, &height))
    {
        [NSException raise:@"CaptureDimensions" format:@"Scaled capture exceeds 64 megapixels"];
    }
    CGSize size = CGSizeMake(width / image.scale, height / image.scale);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

#pragma mark - modes and permissions

/**
 * Whether a mode can ever work here. `accessibility` is Android-only; `auto` is the library's
 * default and always resolves to `view` on this platform, so reporting it unavailable would
 * hide the capture button in any app that gates on isModeAvailable(getMode()).
 */
static BOOL RNSCModeIsSupported(NSString *mode)
{
    return [mode isEqualToString:@"view"] || [mode isEqualToString:@"auto"];
}

RCT_EXPORT_METHOD(getPermissionStatus:(NSString *)mode
                              resolve:(RCTPromiseResolveBlock)resolve
                               reject:(RCTPromiseRejectBlock)reject)
{
    resolve(RNSCModeIsSupported(mode) ? @"granted" : @"unavailable");
}

RCT_EXPORT_METHOD(requestPermission:(NSString *)mode
                            resolve:(RCTPromiseResolveBlock)resolve
                             reject:(RCTPromiseRejectBlock)reject)
{
    resolve(RNSCModeIsSupported(mode) ? @"granted" : @"unavailable");
}

RCT_EXPORT_METHOD(openAccessibilitySettings:(RCTPromiseResolveBlock)resolve
                                     reject:(RCTPromiseRejectBlock)reject)
{
    resolve(@NO);
}

RCT_EXPORT_METHOD(isModeAvailable:(NSString *)mode
                          resolve:(RCTPromiseResolveBlock)resolve
                           reject:(RCTPromiseRejectBlock)reject)
{
    resolve(@(RNSCModeIsSupported(mode)));
}

#pragma mark - frame providers

- (void)performProviderOperation:(dispatch_block_t)operation
                         resolve:(RCTPromiseResolveBlock)resolve
                          reject:(RCTPromiseRejectBlock)reject
{
    [RNSCWindowCapture performSerially:^(dispatch_block_t done) {
        NSError *error = nil;
        @try
        {
            operation();
        }
        @catch (NSException *exception)
        {
            error = [NSError errorWithDomain:@"com.fugood.screencapture"
                                        code:500
                                    userInfo:@{
                                        NSLocalizedDescriptionKey : exception.reason
                                            ?: @"Provider operation failed"
                                    }];
        }
        @finally
        {
            done();
        }
        if (error)
            reject(kErrorCapture, error.localizedDescription, error);
        else
            resolve(nil);
    }];
}

RCT_EXPORT_METHOD(warmUp:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    [self
        performProviderOperation:^{
            RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
            @try
            {
                [registry attachedProvidersForWindows:[RNSCWindowCapture captureWindows]];
            }
            @finally
            {
                [registry scheduleIdleDetach];
            }
        }
                         resolve:resolve
                          reject:reject];
}

RCT_EXPORT_METHOD(coolDown:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject)
{
    [self
        performProviderOperation:^{
            [RNSCProviderRegistry.sharedRegistry detachAll];
        }
                         resolve:resolve
                          reject:reject];
}

#pragma mark - misc

RCT_EXPORT_METHOD(clearCache:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(RNSCFileQueue(), ^{
        NSError *error = nil;
        NSUInteger removed = 0;
        @try
        {
            if ([self isInvalidated])
                [NSException raise:@"CaptureCancelled" format:@"Module is shutting down"];
            removed = [[RNSCFileStore defaultStore] clear:&error];
        }
        @catch (NSException *exception)
        {
            error = RNSCExceptionError(exception);
        }
        if (error)
            reject(kErrorCapture,
                   [NSString stringWithFormat:@"Cache cleanup failed after removing %lu files: %@",
                                              (unsigned long)removed, error.localizedDescription],
                   error);
        else
            resolve(@(removed));
    });
}

RCT_EXPORT_METHOD(releaseCapture : (NSString *)uri resolve : (RCTPromiseResolveBlock)
                      resolve reject : (RCTPromiseRejectBlock)reject)
{
    dispatch_async(RNSCFileQueue(), ^{
        NSError *error = nil;
        BOOL removed = NO;
        @try
        {
            if ([self isInvalidated])
                [NSException raise:@"CaptureCancelled" format:@"Module is shutting down"];
            removed = [[RNSCFileStore defaultStore] releaseURI:uri error:&error];
        }
        @catch (NSException *exception)
        {
            error = RNSCExceptionError(exception);
        }
        if (error)
            reject(kErrorCapture, error.localizedDescription, error);
        else
            resolve(@(removed));
    });
}

RCT_EXPORT_METHOD(startScreenshotDetection:(RCTPromiseResolveBlock)resolve
                                    reject:(RCTPromiseRejectBlock)reject)
{
    if (!_observingScreenshots) {
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(userDidTakeScreenshot:)
                   name:UIApplicationUserDidTakeScreenshotNotification
                 object:nil];
        _observingScreenshots = YES;
    }
    resolve(nil);
}

RCT_EXPORT_METHOD(stopScreenshotDetection:(RCTPromiseResolveBlock)resolve
                                   reject:(RCTPromiseRejectBlock)reject)
{
    [self stopScreenshotObserver];
    resolve(nil);
}

- (void)stopScreenshotObserver
{
    if (!_observingScreenshots) return;
    [NSNotificationCenter.defaultCenter
        removeObserver:self
                  name:UIApplicationUserDidTakeScreenshotNotification
                object:nil];
    _observingScreenshots = NO;
}

- (void)userDidTakeScreenshot:(NSNotification *)notification
{
    // iOS never hands over the user's screenshot file, only the fact that one was taken.
    if (_hasListeners) [self sendEventWithName:kEventScreenshot body:@{}];
}

RCT_EXPORT_METHOD(dumpHierarchy:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject)
{
    [RNSCWindowCapture performSerially:^(dispatch_block_t done) {
        __block NSMutableString *out = nil;
        NSArray<id<RNSCFrameProvider>> *providers = nil;
        NSError *failure = nil;
        RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
        @try
        {
            NSArray<UIWindow *> *windows = [RNSCWindowCapture captureWindows];
            out = [[registry describeWindows:windows] mutableCopy];
            providers = [registry attachedProvidersForWindows:windows];
        }
        @catch (NSException *exception)
        {
            failure = [NSError
                errorWithDomain:@"com.fugood.screencapture"
                           code:500
                       userInfo:@{
                           NSLocalizedDescriptionKey : exception.reason ?: @"Discovery failed"
                       }];
        }
        if (failure)
        {
            [registry scheduleIdleDetach];
            done();
            reject(kErrorCapture, failure.localizedDescription, failure);
            return;
        }
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                NSError *error = nil;
                @try
                {
                    [out appendString:@"\nFRAME PROVIDERS\n"];
                    if (providers.count == 0)
                        [out appendString:@"  (none matched)\n"];
                    for (id<RNSCFrameProvider> provider in providers)
                    {
                        [out appendFormat:@"  %@  hasFrame=%@  gravity=%@  target=%@\n",
                                          provider.identifier, provider.hasFrame ? @"YES" : @"no",
                                          provider.contentsGravity,
                                          NSStringFromClass(provider.targetView.class)];
                    }
                }
                @catch (NSException *exception)
                {
                    error = [NSError errorWithDomain:@"com.fugood.screencapture"
                                                code:500
                                            userInfo:@{
                                                NSLocalizedDescriptionKey : exception.reason
                                                    ?: @"Provider diagnostic failed"
                                            }];
                }
                @finally
                {
                    @try
                    {
                        [registry scheduleIdleDetach];
                    }
                    @finally
                    {
                        done();
                    }
                }
                if (error)
                    reject(kErrorCapture, error.localizedDescription, error);
                else
                    resolve(out);
            });
    }];
}

#pragma mark - TurboModule

#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params
{
    return std::make_shared<facebook::react::NativeScreenCaptureSpecJSI>(params);
}
#endif

@end
