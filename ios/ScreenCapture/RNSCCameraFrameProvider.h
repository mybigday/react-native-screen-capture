//
//  RNSCCameraFrameProvider.h
//  ScreenCapture
//

#import "RNSCFrameProvider.h"

// AVCaptureSession and AVCaptureVideoPreviewLayer are API_UNAVAILABLE(tvos):
// tvOS has no camera. Video capture still works there through AVPlayerLayer.
#if !TARGET_OS_TV


NS_ASSUME_NONNULL_BEGIN

/**
 * Frames for anything rendering through an `AVCaptureVideoPreviewLayer`.
 *
 * Matching on the layer class rather than on a package name means one implementation covers
 * VisionCamera, expo-camera, react-native-camera-kit and anything else built the normal way,
 * with no cooperation needed from those packages and no setup from the app author.
 */
@interface RNSCCameraFrameProvider : NSObject <RNSCFrameProvider>

- (nullable instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer
                                   targetView:(UIView *)targetView NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END

#endif // !TARGET_OS_TV
