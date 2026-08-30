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

/** Visible windows of foreground-active scenes, back to front. */
+ (NSArray<UIWindow *> *)captureWindows;

@end

NS_ASSUME_NONNULL_END
