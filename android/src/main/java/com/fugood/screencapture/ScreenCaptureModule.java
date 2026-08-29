package com.fugood.screencapture;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.provider.Settings;
import android.util.Base64;

import androidx.annotation.Nullable;

import com.facebook.react.bridge.Arguments;
import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableMap;
import com.facebook.react.bridge.UiThreadUtil;
import com.facebook.react.bridge.WritableMap;
import com.facebook.react.modules.core.DeviceEventManagerModule;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

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
        // stop() touches the legacy manager, which is main-thread only, and must not be allowed
        // to skip the rest of teardown if it throws.
        UiThreadUtil.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    detector.stop();
                } catch (Throwable ignored) {
                }
            }
        });
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
        final int quality = Math.max(0, Math.min(100,
            options.hasKey("quality") ? (int) options.getDouble("quality") : 100));
        final double scale = options.hasKey("scale") ? options.getDouble("scale") : 1d;
        final boolean includeBase64 =
            options.hasKey("includeBase64") && options.getBoolean("includeBase64");

        // `view` mode crops as part of the readback on API 26+, and right after it on 24-25.
        // A whole-display capture cannot crop at source, so accessibility mode defers to
        // encode(), which is on a worker thread inside a try/catch. The height is resolved there
        // too, not here: this method runs on the module thread, and resolving it eagerly would
        // also let it go stale across the service's retry or a rotation.
        final boolean cropStatusBar = MODE_ACCESSIBILITY.equals(mode) && excludeStatusBar;

        final CaptureCallback onBitmap = new CaptureCallback() {
            @Override
            public void onResult(@Nullable Bitmap bitmap, @Nullable String error) {
                if (bitmap == null) {
                    promise.reject(E_CAPTURE, error != null ? error : "Capture failed");
                    return;
                }
                encode(bitmap, extension, quality, scale, includeBase64, cropStatusBar, promise);
            }
        };

        if (MODE_ACCESSIBILITY.equals(mode)) {
            // WindowCapture.capture() owns this guarantee for the view path; the accessibility
            // path has to arrange it here. Without the wrap, a throw out of the service's own
            // synchronous settle would come back through the catch as a second settle; without
            // the catch, it would leave the Promise pending forever.
            final CaptureCallback guarded = WindowCapture.once(onBitmap);
            try {
                ScreenCaptureAccessibilityService.capture(guarded);
            } catch (Throwable t) {
                guarded.onResult(null, String.valueOf(t.getMessage()));
            }
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
                        final double scale, final boolean includeBase64,
                        final boolean cropStatusBar, final Promise promise) {
        final Runnable work = new Runnable() {
            @Override
            public void run() {
                Bitmap bitmap = source;
                WritableMap result = null;
                Throwable failure = null;
                try {
                    int top = cropStatusBar
                        ? WindowCapture.nominalStatusBarHeight(reactContext) : 0;
                    if (top < 0 || top >= source.getHeight()) top = 0;
                    final boolean resize = scale > 0 && scale != 1d;
                    if (top > 0 || resize) {
                        final int srcWidth = source.getWidth();
                        final int srcHeight = source.getHeight() - top;
                        Matrix matrix = null;
                        if (resize) {
                            // Derive the matrix from clamped target dimensions: scaling by the
                            // raw factor can round a dimension to 0, which createBitmap rejects.
                            int dstWidth = Math.max(1, (int) Math.round(srcWidth * scale));
                            int dstHeight = Math.max(1, (int) Math.round(srcHeight * scale));
                            matrix = new Matrix();
                            matrix.postScale((float) dstWidth / srcWidth,
                                             (float) dstHeight / srcHeight);
                        }
                        // One allocation for both. Cropping and then rescaling would hold two
                        // full-display bitmaps at once on top of the one the caller handed us.
                        bitmap = Bitmap.createBitmap(
                            source, 0, top, srcWidth, srcHeight, matrix, true);
                        if (bitmap != source) source.recycle();
                    }

                    Bitmap.CompressFormat format = compressFormat(extension);
                    // Normalised so the URI suffix matches iOS, which always writes .jpg.
                    String suffix = format == Bitmap.CompressFormat.JPEG ? "jpg" : "png";
                    File file = File.createTempFile(FILE_PREFIX, "." + suffix,
                        reactContext.getCacheDir());

                    byte[] encoded = null;
                    if (includeBase64) {
                        // Encode once and reuse the bytes for both the file and the string;
                        // compressing twice doubles the cost of every base64 capture.
                        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                        bitmap.compress(format, quality, buffer);
                        encoded = buffer.toByteArray();
                    }

                    FileOutputStream out = new FileOutputStream(file);
                    try {
                        if (encoded != null) {
                            out.write(encoded);
                        } else {
                            bitmap.compress(format, quality, out);
                        }
                        out.flush();
                    } finally {
                        out.close();
                    }

                    result = Arguments.createMap();
                    result.putString("uri", "file://" + file.getAbsolutePath());
                    result.putInt("width", bitmap.getWidth());
                    result.putInt("height", bitmap.getHeight());
                    if (encoded != null) {
                        result.putString("base64", Base64.encodeToString(encoded, Base64.NO_WRAP));
                    }
                } catch (Throwable t) {
                    failure = t;
                } finally {
                    if (!bitmap.isRecycled()) bitmap.recycle();
                }
                // Outside the try: a throw out of resolve() must not come back round as a
                // reject on the Promise it just settled.
                if (failure != null) {
                    promise.reject(E_CAPTURE, String.valueOf(failure.getMessage()), failure);
                } else {
                    promise.resolve(result);
                }
            }
        };
        try {
            encoder.execute(work);
        } catch (RejectedExecutionException e) {
            // invalidate() shuts the encoder down. Without this the rejection would escape into
            // the accessibility service's unguarded callback and the Promise would never settle.
            source.recycle();
            promise.reject(E_CAPTURE, "Module is shutting down", e);
        }
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
        if (!ScreenCaptureAccessibilityService.isSupported()
            || !ScreenCaptureAccessibilityService.isDeclared(reactContext)) {
            // A service the host app never declared can never be granted, so reporting "denied"
            // would send it round a loop no user action can end.
            promise.resolve("unavailable");
            return;
        }
        // Only "granted" once the service is actually bound. Enabled-but-not-yet-bound has to
        // report denied, or `auto` picks accessibility and the capture hard-rejects instead of
        // falling back to `view`.
        promise.resolve(ScreenCaptureAccessibilityService.isConnected() ? "granted" : "denied");
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
        if (!ScreenCaptureAccessibilityService.isDeclared(reactContext)) {
            // Settings would open on a list that does not contain this app's service.
            promise.resolve("unavailable");
            return;
        }
        if (ScreenCaptureAccessibilityService.isEnabled(reactContext)) {
            // Already switched on, just not bound yet. Sending them back to Settings for a
            // toggle that is already flipped is worse than telling them to wait.
            promise.resolve("denied");
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
            promise.resolve(ScreenCaptureAccessibilityService.isSupported()
                && ScreenCaptureAccessibilityService.isDeclared(reactContext));
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
    public void clearCache(final Promise promise) {
        // On the new architecture TurboModule methods run on the JS thread. Listing the cache
        // and unlinking one file per capture is real syscall work -- after a burst of PNGs it
        // is dozens of them -- so it goes to the same executor the encoder uses.
        final Runnable work = new Runnable() {
            @Override
            public void run() {
                int removed = 0;
                Throwable failure = null;
                try {
                    File[] files = reactContext.getCacheDir().listFiles();
                    if (files != null) {
                        for (File file : files) {
                            if (file.getName().startsWith(FILE_PREFIX) && file.delete()) removed++;
                        }
                    }
                } catch (Throwable t) {
                    failure = t;
                }
                // Outside the try, as everywhere else here: settling must not be able to settle
                // again through the catch.
                if (failure != null) {
                    promise.reject(E_CAPTURE, String.valueOf(failure.getMessage()), failure);
                } else {
                    promise.resolve(removed);
                }
            }
        };
        try {
            encoder.execute(work);
        } catch (RejectedExecutionException e) {
            // invalidate() shuts the encoder down.
            promise.reject(E_CAPTURE, "Module is shutting down", e);
        }
    }

    @Override
    @ReactMethod
    public void startScreenshotDetection(final Promise promise) {
        // The pre-API-34 manager asserts it is on the main thread; @ReactMethods are not.
        UiThreadUtil.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                startDetectionOnUiThread(promise);
            }
        });
    }

    private void startDetectionOnUiThread(final Promise promise) {
        try {
            detector.start(new ScreenshotDetector.Listener() {
                @Override
                public void onScreenshot(@Nullable String path) {
                    WritableMap event = Arguments.createMap();
                    if (path != null) {
                        event.putString("uri", path.startsWith("file://") ? path : "file://" + path);
                    }
                    // Runs on the main thread from a system callback, so it owns its failures:
                    // detection can outlive the React instance by a moment (invalidate() only
                    // posts the stop), and emitting into a torn-down instance throws.
                    try {
                        if (!reactContext.hasActiveReactInstance()) return;
                        reactContext
                            .getJSModule(DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                            .emit(EVENT_SCREENSHOT, event);
                    } catch (Throwable ignored) {
                    }
                }
            });
            promise.resolve(null);
        } catch (Throwable t) {
            promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
        }
    }

    @Override
    @ReactMethod
    public void stopScreenshotDetection(final Promise promise) {
        UiThreadUtil.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    detector.stop();
                    promise.resolve(null);
                } catch (Throwable t) {
                    promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
                }
            }
        });
    }

    @Override
    @ReactMethod
    public void dumpHierarchy(final Promise promise) {
        UiThreadUtil.runOnUiThread(new Runnable() {
            @Override
            public void run() {
                try {
                    promise.resolve(WindowCapture.dump(getCurrentActivity()));
                } catch (Throwable t) {
                    promise.reject(E_CAPTURE, String.valueOf(t.getMessage()), t);
                }
            }
        });
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
