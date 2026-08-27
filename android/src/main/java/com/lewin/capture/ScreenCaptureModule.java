package com.lewin.capture;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.provider.Settings;
import android.util.Base64;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class ScreenCaptureModule extends ScreenCaptureSpec {

    public static final String NAME = "ScreenCapture";

    private static final String FILE_PREFIX = "CAPTURE";
    private static final String EVENT_SCREENSHOT = "ScreenCapture";
    private static final String MODE_ACCESSIBILITY = "accessibility";

    private static final String E_CAPTURE = "E_CAPTURE";
    private static final String E_NO_ACTIVITY = "E_NO_ACTIVITY";

    private final ReactApplicationContext reactContext;
    private final ExecutorService encoder = Executors.newSingleThreadExecutor();
    private final ScreenshotDetector detector;

    public ScreenCaptureModule(ReactApplicationContext reactContext) {
        super(reactContext);
        this.reactContext = reactContext;
        this.detector = new ScreenshotDetector(reactContext);
    }

    @Override
    public String getName() {
        return NAME;
    }

    @Override
    public void invalidate() {
        detector.stop();
        encoder.shutdown();
        super.invalidate();
    }

    // region capture

    @Override
    @ReactMethod
    public void capture(ReadableMap options, final Promise promise) {
        final String mode = options.hasKey("mode") ? options.getString("mode") : "view";
        final boolean excludeStatusBar =
            options.hasKey("excludeStatusBar") && options.getBoolean("excludeStatusBar");
        final String extension = options.hasKey("extension") ? options.getString("extension") : "png";
        final int quality = options.hasKey("quality") ? (int) options.getDouble("quality") : 100;
        final double scale = options.hasKey("scale") ? options.getDouble("scale") : 1d;
        final boolean includeBase64 =
            options.hasKey("includeBase64") && options.getBoolean("includeBase64");

        final WindowCapture.Callback onBitmap = new WindowCapture.Callback() {
            @Override
            public void onResult(@Nullable Bitmap bitmap, @Nullable String error) {
                if (bitmap == null) {
                    promise.reject(E_CAPTURE, error != null ? error : "Capture failed");
                    return;
                }
                encode(bitmap, extension, quality, scale, includeBase64, promise);
            }
        };

        if (MODE_ACCESSIBILITY.equals(mode)) {
            ScreenCaptureAccessibilityService.capture(new ScreenCaptureAccessibilityService.Callback() {
                @Override
                public void onResult(@Nullable Bitmap bitmap, @Nullable String error) {
                    onBitmap.onResult(bitmap, error);
                }
            });
            return;
        }

        Activity activity = getCurrentActivity();
        if (activity == null) {
            promise.reject(E_NO_ACTIVITY, "No current activity");
            return;
        }
        WindowCapture.capture(activity, excludeStatusBar, onBitmap);
    }

    private void encode(final Bitmap source, final String extension, final int quality,
                        final double scale, final boolean includeBase64, final Promise promise) {
        encoder.execute(new Runnable() {
            @Override
            public void run() {
                Bitmap bitmap = source;
                try {
                    if (scale > 0 && scale != 1d) {
                        int width = Math.max(1, (int) Math.round(source.getWidth() * scale));
                        int height = Math.max(1, (int) Math.round(source.getHeight() * scale));
                        bitmap = Bitmap.createScaledBitmap(source, width, height, true);
                        if (bitmap != source) source.recycle();
                    }

                    Bitmap.CompressFormat format = compressFormat(extension);
                    File file = File.createTempFile(FILE_PREFIX, "." + extension,
                        reactContext.getCacheDir());
                    FileOutputStream out = new FileOutputStream(file);
                    try {
                        bitmap.compress(format, quality, out);
                        out.flush();
                    } finally {
                        out.close();
                    }

                    WritableMap result = Arguments.createMap();
                    result.putString("uri", "file://" + file.getAbsolutePath());
                    result.putInt("width", bitmap.getWidth());
                    result.putInt("height", bitmap.getHeight());
                    if (includeBase64) {
                        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                        bitmap.compress(format, quality, buffer);
                        result.putString("base64",
                            Base64.encodeToString(buffer.toByteArray(), Base64.NO_WRAP));
                    }
                    promise.resolve(result);
                } catch (Throwable t) {
                    promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
                } finally {
                    if (!bitmap.isRecycled()) bitmap.recycle();
                }
            }
        });
    }

    private static Bitmap.CompressFormat compressFormat(String extension) {
        if ("jpg".equals(extension) || "jpeg".equals(extension)) {
            return Bitmap.CompressFormat.JPEG;
        }
        return Bitmap.CompressFormat.PNG;
    }

    // endregion
    // region permissions

    @Override
    @ReactMethod
    public void getPermissionStatus(String mode, Promise promise) {
        if (!MODE_ACCESSIBILITY.equals(mode)) {
            promise.resolve("granted");
            return;
        }
        if (!ScreenCaptureAccessibilityService.isSupported()) {
            promise.resolve("unavailable");
            return;
        }
        boolean ready = ScreenCaptureAccessibilityService.isConnected()
            || ScreenCaptureAccessibilityService.isEnabled(reactContext);
        promise.resolve(ready ? "granted" : "denied");
    }

    @Override
    @ReactMethod
    public void requestPermission(String mode, final Promise promise) {
        if (!MODE_ACCESSIBILITY.equals(mode)) {
            promise.resolve("granted");
            return;
        }
        if (!ScreenCaptureAccessibilityService.isSupported()) {
            promise.resolve("unavailable");
            return;
        }
        if (ScreenCaptureAccessibilityService.isConnected()) {
            promise.resolve("granted");
            return;
        }
        // The service can only be switched on by the user, so all we can do is take them there.
        openSettings();
        promise.resolve("denied");
    }

    @Override
    @ReactMethod
    public void openAccessibilitySettings(Promise promise) {
        try {
            openSettings();
            promise.resolve(true);
        } catch (Throwable t) {
            promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
        }
    }

    private void openSettings() {
        Intent intent = new Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS);
        Activity activity = getCurrentActivity();
        if (activity != null) {
            activity.startActivity(intent);
        } else {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            reactContext.startActivity(intent);
        }
    }

    @Override
    @ReactMethod
    public void isModeAvailable(String mode, Promise promise) {
        if (MODE_ACCESSIBILITY.equals(mode)) {
            promise.resolve(ScreenCaptureAccessibilityService.isSupported());
        } else {
            promise.resolve(true);
        }
    }

    // endregion
    // region frame providers (iOS only)

    @Override
    @ReactMethod
    public void warmUp(Promise promise) {
        promise.resolve(null);
    }

    @Override
    @ReactMethod
    public void coolDown(Promise promise) {
        promise.resolve(null);
    }

    // endregion
    // region misc

    @Override
    @ReactMethod
    public void clearCache(Promise promise) {
        int removed = 0;
        File[] files = reactContext.getCacheDir().listFiles();
        if (files != null) {
            for (File file : files) {
                if (file.getName().startsWith(FILE_PREFIX) && file.delete()) removed++;
            }
        }
        promise.resolve(removed);
    }

    @Override
    @ReactMethod
    public void startScreenshotDetection(Promise promise) {
        try {
            detector.start(getCurrentActivity(), new ScreenshotDetector.Listener() {
                @Override
                public void onScreenshot(@Nullable String path) {
                    WritableMap event = Arguments.createMap();
                    if (path != null) {
                        event.putString("uri", path.startsWith("file://") ? path : "file://" + path);
                    }
                    reactContext
                        .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                        .emit(EVENT_SCREENSHOT, event);
                }
            });
            promise.resolve(null);
        } catch (Throwable t) {
            promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
        }
    }

    @Override
    @ReactMethod
    public void stopScreenshotDetection(Promise promise) {
        detector.stop();
        promise.resolve(null);
    }

    @Override
    @ReactMethod
    public void dumpHierarchy(Promise promise) {
        promise.resolve(WindowCapture.dump(getCurrentActivity()));
    }

    @Override
    @ReactMethod
    public void addListener(String eventName) {
        // Required by NativeEventEmitter; the detector is started explicitly.
    }

    @Override
    @ReactMethod
    public void removeListeners(double count) {
        // Required by NativeEventEmitter.
    }

    // endregion
}
