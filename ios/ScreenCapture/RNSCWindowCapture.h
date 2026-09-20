//
//  RNSCWindowCapture.h
//  ScreenCapture
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RNSCWindowCapture : NSObject

/**
 * Captures every visible window of the app, with media components composited in.
 *
 * Completion runs on the main thread. `image` is nil when `error` is set.
 */
+ (void)captureExcludingStatusBar:(BOOL)excludeStatusBar
                       completion:(void (^)(UIImage *_Nullable image,
                                            NSError *_Nullable error))completion;

/**
 * As above, for one screen or all of them.
 *
 * `screenSelector` is `all` (every screen this app is showing on, stitched side by side),
 * `main` (the built-in screen only), or the index of a screen in `UIScreen.screens`.
 */
+ (void)captureExcludingStatusBar:(BOOL)excludeStatusBar
                           screen:(NSString *)screenSelector
                  markUnsupported:(BOOL)markUnsupported
                       completion:(void (^)(UIImage *_Nullable image,
                                            NSError *_Nullable error))completion;

/** Visible windows of foreground-active scenes, back to front. */
+ (NSArray<UIWindow *> *)captureWindows;

@end

NS_ASSUME_NONNULL_END
