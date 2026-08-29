//
//  ScreenCapture.mm
//  ScreenCapture
//

#import "ScreenCapture.h"
#import "RNSCWindowCapture.h"
#import "RNSCProviderRegistry.h"

#import <UIKit/UIKit.h>

static NSString *const kCacheFolder = @"react-native-screen-capture";
static NSString *const kEventScreenshot = @"ScreenCapture";
static NSString *const kErrorCapture = @"E_CAPTURE";
static NSString *const kErrorUnsupported = @"E_UNSUPPORTED";

@implementation ScreenCapture {
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
    [self stopScreenshotObserver];
    // The registry is main-thread only: its timer lives on the main run loop and its provider
    // map is mutated during discovery. invalidate() runs on the module's queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        [RNSCProviderRegistry.sharedRegistry detachAll];
    });
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

    [RNSCWindowCapture captureExcludingStatusBar:excludeStatusBar
                                      completion:^(UIImage *image, NSError *error) {
        if (!image) {
            reject(kErrorCapture, error.localizedDescription ?: @"Capture failed", error);
            return;
        }
        // Scaling and encoding are pure pixel work; keep them off the main thread.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
    @try {
        UIImage *output = (scale > 0 && scale != 1.0) ? [self scaleImage:image by:scale] : image;

        BOOL isJPEG = [extension isEqualToString:@"jpg"] || [extension isEqualToString:@"jpeg"];
        NSData *data = isJPEG ? UIImageJPEGRepresentation(output, MAX(0.0, MIN(1.0, quality / 100.0)))
                              : UIImagePNGRepresentation(output);
        if (!data) {
            reject(kErrorCapture, @"Could not encode the image", nil);
            return;
        }

        NSString *path = [self writeData:data extension:isJPEG ? @"jpg" : @"png"];
        if (!path) {
            reject(kErrorCapture, @"Could not write the image to the cache directory", nil);
            return;
        }

        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"uri"] = [@"file://" stringByAppendingString:path];
        // From the CGImage, not size * scale: the renderer rounds fractional point sizes, so a
        // scaled capture would otherwise report a non-integer width that disagrees with the
        // file just written -- and with Android, which returns an exact pixel count.
        CGImageRef cgImage = output.CGImage;
        result[@"width"] = @(cgImage ? (NSInteger)CGImageGetWidth(cgImage)
                                     : (NSInteger)lround(output.size.width * output.scale));
        result[@"height"] = @(cgImage ? (NSInteger)CGImageGetHeight(cgImage)
                                      : (NSInteger)lround(output.size.height * output.scale));
        if (includeBase64) {
            result[@"base64"] = [data base64EncodedStringWithOptions:0];
        }
        resolve(result);
    } @catch (NSException *exception) {
        reject(kErrorCapture, exception.reason ?: @"Capture failed", nil);
    }
}

- (UIImage *)scaleImage:(UIImage *)image by:(CGFloat)scale
{
    CGSize size = CGSizeMake(image.size.width * scale, image.size.height * scale);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

- (nullable NSString *)writeData:(NSData *)data extension:(NSString *)extension
{
    NSString *folder = [self cacheFolder];
    if (!folder) return nil;
    NSString *name = [NSString stringWithFormat:@"CAPTURE-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSString *path = [folder stringByAppendingPathComponent:name];
    return [data writeToFile:path atomically:YES] ? path : nil;
}

- (nullable NSString *)cacheFolder
{
    NSString *caches =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (!caches) return nil;
    NSString *folder = [caches stringByAppendingPathComponent:kCacheFolder];
    NSFileManager *manager = NSFileManager.defaultManager;
    if (![manager fileExistsAtPath:folder]) {
        [manager createDirectoryAtPath:folder
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:NULL];
    }
    return folder;
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

RCT_EXPORT_METHOD(warmUp:(RCTPromiseResolveBlock)resolve
                  reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
        [registry attachedProvidersForWindows:[RNSCWindowCapture captureWindows]];
        // attachedProvidersForWindows: cancels the idle timer; without re-arming it here a
        // warmUp() that is never followed by a capture would keep the providers attached for
        // the life of the app, which is not what the API documents.
        [registry scheduleIdleDetach];
        resolve(nil);
    });
}

RCT_EXPORT_METHOD(coolDown:(RCTPromiseResolveBlock)resolve
                    reject:(RCTPromiseRejectBlock)reject)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [RNSCProviderRegistry.sharedRegistry detachAll];
        resolve(nil);
    });
}

#pragma mark - misc

RCT_EXPORT_METHOD(clearCache:(RCTPromiseResolveBlock)resolve
                      reject:(RCTPromiseRejectBlock)reject)
{
    NSString *folder = [self cacheFolder];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSUInteger removed = 0;
    if (folder) {
        NSArray<NSString *> *names = [manager contentsOfDirectoryAtPath:folder error:NULL];
        for (NSString *name in names) {
            NSString *path = [folder stringByAppendingPathComponent:name];
            if ([manager removeItemAtPath:path error:NULL]) removed++;
        }
    }
    resolve(@(removed));
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
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<UIWindow *> *windows = [RNSCWindowCapture captureWindows];
        RNSCProviderRegistry *registry = RNSCProviderRegistry.sharedRegistry;
        NSMutableString *out = [[registry describeWindows:windows] mutableCopy];

        // Attaching is what tells us whether a matched component can actually hand over
        // frames -- discovery finding a layer is not the same as the pipeline working.
        NSArray<id<RNSCFrameProvider>> *providers = [registry attachedProvidersForWindows:windows];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [out appendString:@"\nFRAME PROVIDERS\n"];
            if (providers.count == 0) {
                [out appendString:@"  (none matched)\n"];
            }
            for (id<RNSCFrameProvider> provider in providers) {
                [out appendFormat:@"  %@  hasFrame=%@  gravity=%@  target=%@\n",
                    provider.identifier,
                    provider.hasFrame ? @"YES" : @"no",
                    provider.contentsGravity,
                    NSStringFromClass(provider.targetView.class)];
            }
            [registry scheduleIdleDetach];
            resolve(out);
        });
    });
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
