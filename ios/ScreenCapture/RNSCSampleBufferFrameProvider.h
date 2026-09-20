//
//  RNSCSampleBufferFrameProvider.h
//  ScreenCapture
//

#import "RNSCFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Frames for an `AVSampleBufferDisplayLayer`.
 *
 * Unlike the player and camera providers there is nothing to hook into:
 * `AVSampleBufferVideoRenderer` hands back exactly the buffer the layer is showing, on demand.
 * So `attach` / `detach` do nothing and the layer pays no cost for being captured.
 *
 * That needs **iOS 17.4** -- `sampleBufferRenderer` arrived in 17.0 and
 * `-copyDisplayedPixelBuffer` on it in 17.4. Below that there is no public read-back, and
 * `initWithDisplayLayer:` returns nil rather than pretending otherwise: the region then renders
 * however `drawViewHierarchyInRect:` leaves it, which on device is black.
 */
@interface RNSCSampleBufferFrameProvider : NSObject <RNSCFrameProvider>

- (nullable instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)layer
                                   targetView:(UIView *)targetView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
