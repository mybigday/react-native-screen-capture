//
//  RNSCPlayerFrameProvider.h
//  ScreenCapture
//

#import "RNSCFrameProvider.h"

NS_ASSUME_NONNULL_BEGIN

/** Frames from public AVPlayer properties; protected playback may return no frame. */
@interface RNSCPlayerFrameProvider : NSObject <RNSCFrameProvider>

- (nullable instancetype)initWithPlayer:(AVPlayer *)player
                             targetView:(UIView *)targetView
                             mediaLayer:(nullable CALayer *)mediaLayer
                                gravity:(CALayerContentsGravity)gravity NS_DESIGNATED_INITIALIZER;

+ (NSString *)identifierForPlayer:(AVPlayer *)player
                             view:(UIView *)view
                            layer:(nullable CALayer *)layer;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
