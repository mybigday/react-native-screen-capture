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
@interface RNSCProviderRegistry : NSObject

@property (class, nonatomic, readonly) RNSCProviderRegistry *sharedRegistry;

/** Discovers, caches and attaches. Call on the main thread. */
- (NSArray<id<RNSCFrameProvider>> *)attachedProvidersForWindows:(NSArray<UIWindow *> *)windows;

/** Restarts the idle countdown. Call once a capture finishes. */
- (void)scheduleIdleDetach;

- (void)detachAll;

/** Backs the dev-only `dumpHierarchy()`. */
- (NSString *)describeWindows:(NSArray<UIWindow *> *)windows;

@end

NS_ASSUME_NONNULL_END
