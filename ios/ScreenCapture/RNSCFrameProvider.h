//
//  RNSCFrameProvider.h
//  ScreenCapture
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/** Supplies AVFoundation frames unavailable to hierarchy drawing on hardware. */
@protocol RNSCFrameProvider <NSObject>

/** The view that hosts the media layer. Weak, because the tree changes under us. */
@property (nonatomic, weak, readonly, nullable) UIView *targetView;

/** The media layer itself, when reachable. The placeholder is its first child layer. */
@property (nonatomic, weak, readonly, nullable) CALayer *mediaLayer;

/** Stable identity of this presentation; camera presentations share one frame reader. */
@property (nonatomic, copy, readonly) NSString *identifier;

/** Still worth keeping around? Providers whose target view is gone are dropped. */
@property (nonatomic, readonly, getter=isAlive) BOOL alive;

/** Attach idempotently; the registry releases idle decoder hooks. */
- (void)attach;
- (void)detach;

/** Changes when discovery reacquires a hook, invalidating readiness established earlier. */
@optional
@property(nonatomic, readonly) NSUInteger attachmentGeneration;
@required

/** Whether a frame is available right now. False right after attaching. */
- (BOOL)hasFrame;

/** Caller owns the result. */
- (CGImageRef _Nullable)newFrameImage CF_RETURNS_RETAINED;

/** kCAGravity* constant matching the component's own video gravity. */
- (CALayerContentsGravity)contentsGravity;

/** Mirroring / rotation needed to match what is on screen. Often the identity. */
- (CATransform3D)contentsTransform;

@end

/** Shared, Metal-backed where possible. Creating one per conversion is very expensive. */
FOUNDATION_EXPORT CIContext *RNSCSharedCIContext(void);

/** Converts a pixel buffer to a CGImage using the shared context. Caller owns the result. */
FOUNDATION_EXPORT CGImageRef _Nullable RNSCCreateImageFromPixelBuffer(CVPixelBufferRef buffer)
    CF_RETURNS_RETAINED;

/** Maps AVLayerVideoGravity onto the matching kCAGravity constant. */
FOUNDATION_EXPORT CALayerContentsGravity RNSCContentsGravityForVideoGravity(
    AVLayerVideoGravity _Nullable gravity);

NS_ASSUME_NONNULL_END
