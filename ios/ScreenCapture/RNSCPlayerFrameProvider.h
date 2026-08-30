//
//  RNSCPlayerFrameProvider.h
//  ScreenCapture
//

#import "RNSCFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN

/**
 * Frames for anything driving an `AVPlayer`, whether it is presented through an
 * `AVPlayerLayer` or an `AVPlayerViewController`.
 *
 * We deliberately key off `AVPlayer`, which is reachable through public properties on both
 * (`AVPlayerLayer.player`, `AVPlayerViewController.player`), rather than off the private layer
 * class `AVPlayerViewController` happens to use today. That covers react-native-video,
 * expo-video and expo-av, and survives Apple changing their internals.
 *
 * FairPlay-protected content still comes out black: those frames never leave the secure path,
 * so `AVPlayerItemVideoOutput` returns nothing. That is not fixable from an app.
 */
@interface RNSCPlayerFrameProvider : NSObject <RNSCFrameProvider>

- (nullable instancetype)initWithPlayer:(AVPlayer *)player
                             targetView:(UIView *)targetView
                             mediaLayer:(nullable CALayer *)mediaLayer
                                gravity:(CALayerContentsGravity)gravity NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
