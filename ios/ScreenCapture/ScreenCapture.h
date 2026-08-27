//
//  ScreenCapture.h
//  ScreenCapture
//

#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>

#ifdef RCT_NEW_ARCH_ENABLED
#import <RNScreenCaptureSpec/RNScreenCaptureSpec.h>

@interface ScreenCapture : RCTEventEmitter <NativeScreenCaptureSpec>
#else

@interface ScreenCapture : RCTEventEmitter <RCTBridgeModule>
#endif

@end
