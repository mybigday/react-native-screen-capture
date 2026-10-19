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

- (BOOL)matchesSession:(AVCaptureSession *)session;
+ (NSString *)sourceIdentifierForPreview:(AVCaptureVideoPreviewLayer *)preview;
- (BOOL)matchesPreview:(AVCaptureVideoPreviewLayer *)preview;
- (void)retainPresentation;
- (void)releasePresentation;
- (void)releasePresentationIfIdle;
- (CATransform3D)contentsTransformForPreview:(AVCaptureVideoPreviewLayer *)preview;
- (instancetype)init NS_UNAVAILABLE;

@end

/** Preview layers of the same input stream share a reader without nesting delegate wrappers. */
@interface RNSCCameraPresentation : NSObject <RNSCFrameProvider>
- (instancetype)initWithSource:(RNSCCameraFrameProvider *)source
                       preview:(AVCaptureVideoPreviewLayer *)preview
                          view:(UIView *)view;
@end

NS_ASSUME_NONNULL_END

#endif // !TARGET_OS_TV
