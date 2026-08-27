package com.lewin.capture;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReadableMap;

/** Old-architecture stand-in for the codegen-generated spec. */
abstract class ScreenCaptureSpec extends ReactContextBaseJavaModule {

    ScreenCaptureSpec(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    public abstract void capture(ReadableMap options, Promise promise);

    public abstract void getPermissionStatus(String mode, Promise promise);

    public abstract void requestPermission(String mode, Promise promise);

    public abstract void openAccessibilitySettings(Promise promise);

    public abstract void isModeAvailable(String mode, Promise promise);

    public abstract void warmUp(Promise promise);

    public abstract void coolDown(Promise promise);

    public abstract void clearCache(Promise promise);

    public abstract void startScreenshotDetection(Promise promise);

    public abstract void stopScreenshotDetection(Promise promise);

    public abstract void dumpHierarchy(Promise promise);

    public abstract void addListener(String eventName);

    public abstract void removeListeners(double count);
}
