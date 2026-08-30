//
//  RNSCFrameProvider.h
//  ScreenCapture
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Supplies the current frame of a media component that Core Graphics cannot render.
 *
 * `drawViewHierarchyInRect:` goes through Core Graphics, so layers that are composited by the
 * GPU / render server -- AVPlayerLayer, AVCaptureVideoPreviewLayer, AVSampleBufferDisplayLayer --
 * come out black on device (they render fine in the Simulator, which is what makes this look
 * like it works). The only public way around it is to pull the frame out of the framework that
 * owns it, which is what implementations of this protocol do.
 */
@protocol RNSCFrameProvider <NSObject>

/** The view that hosts the media layer. Weak, because the tree changes under us. */
@property (nonatomic, weak, readonly, nullable) UIView *targetView;

/** The media layer itself, when we could reach it. The placeholder goes directly above it. */
@property (nonatomic, weak, readonly, nullable) CALayer *mediaLayer;

/** Stable identity of the underlying pipeline, so we do not attach to it twice. */
@property (nonatomic, copy, readonly) NSString *identifier;

/** Still worth keeping around? Providers whose target view is gone are dropped. */
@property (nonatomic, readonly, getter=isAlive) BOOL alive;

/**
 * Hook into the underlying pipeline. Idempotent.
 *
 * Attaching is not free -- an AVPlayerItemVideoOutput makes the decoder emit an extra
 * app-readable copy -- so the registry detaches everything again after a few idle seconds.
 */
- (void)attach;
- (void)detach;

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
