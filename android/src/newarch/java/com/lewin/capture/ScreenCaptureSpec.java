package com.lewin.capture;

import com.facebook.react.bridge.ReactApplicationContext;

/** New-architecture spec: everything comes from codegen. */
abstract class ScreenCaptureSpec extends NativeScreenCaptureSpec {

    ScreenCaptureSpec(ReactApplicationContext reactContext) {
        super(reactContext);
    }
}
