//
//  RNSCProviderRegistry.h
//  ScreenCapture
//

#import "RNSCFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Finds the media components in a view tree and keeps their frame providers around between
 * captures.
 *
 * Discovery is pure introspection -- we look for AVFoundation objects reached through public
 * properties, never for package names or private classes -- so supporting a package requires
 * nothing from that package and no configuration from the app.
 *
 * Providers are attached lazily and detached again after a few idle seconds, so an app that
 * never calls `capture()` pays nothing at all.
 */
/** A media layer we can see but cannot read, and why. */
@interface RNSCUnreachableLayer : NSObject
@property (nonatomic, weak, readonly, nullable) UIView *targetView;
@property (nonatomic, weak, readonly, nullable) CALayer *mediaLayer;
@property (nonatomic, copy, readonly) NSString *reason;
@end

@interface RNSCProviderRegistry : NSObject

@property (class, nonatomic, readonly) RNSCProviderRegistry *sharedRegistry;

/** Discovers, caches and attaches. Call on the main thread. */
- (NSArray<id<RNSCFrameProvider>> *)attachedProvidersForWindows:(NSArray<UIWindow *> *)windows;

/** Restarts the idle countdown. Call once a capture finishes. */
- (void)scheduleIdleDetach;

- (void)detachAll;

/** Backs the dev-only `dumpHierarchy()`. */
- (NSString *)describeWindows:(NSArray<UIWindow *> *)windows;

/**
 * Media layers this build recognises but cannot pull a frame from on this OS.
 *
 * Today that is an `AVSampleBufferDisplayLayer` below iOS 17.4, where no public read-back
 * exists. They are reported so `capture({ markUnsupported: true })` can label the region
 * instead of leaving a black rectangle nobody can explain.
 */
- (NSArray<RNSCUnreachableLayer *> *)unreachableLayersForWindows:(NSArray<UIWindow *> *)windows;

@end

NS_ASSUME_NONNULL_END
