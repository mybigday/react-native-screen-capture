package com.fugood.screencapture;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;

import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

/**
 * Whole-display capture through {@link AccessibilityService#takeScreenshot}. Unlike the default
 * {@code view} mode this sees other apps, real system bars and dialogs, and needs no per-capture
 * consent -- but the user has to switch the service on in Settings once.
 *
 * <p>This service is deliberately <b>not</b> declared in the library manifest. Manifest merging
 * would push an accessibility service onto every consumer app and drag all of them into Google
 * Play's Accessibility API policy review, including apps that only ever use {@code view} mode.
 * App authors opt in by declaring it themselves -- see the README.
 */
public class ScreenCaptureAccessibilityService extends AccessibilityService {

    interface Callback {
        void onResult(@Nullable Bitmap bitmap, @Nullable String error);
    }

    private static final int RETRY_DELAY_MS = 400;

    /**
     * The screenshot callback copies a full-screen bitmap out of the hardware buffer. Running
     * that on the main executor would do a 1080x2340-sized copy on the UI thread.
     */
    private static final Executor CAPTURE_EXECUTOR = Executors.newSingleThreadExecutor(
        new ThreadFactory() {
            @Override
            public Thread newThread(Runnable runnable) {
                return new Thread(runnable, "rn-screen-capture-a11y");
            }
        });

    @Nullable
    private static volatile ScreenCaptureAccessibilityService instance;

    @Override
    protected void onServiceConnected() {
        super.onServiceConnected();
        instance = this;
    }

    @Override
    public boolean onUnbind(Intent intent) {
        instance = null;
        return super.onUnbind(intent);
    }

    @Override
    public void onDestroy() {
        instance = null;
        super.onDestroy();
    }

    @Override
    public void onAccessibilityEvent(AccessibilityEvent event) {
        // Capture-only service; we do not react to events.
    }

    @Override
    public void onInterrupt() {
    }

    /** Whether this OS version has the screenshot API at all. */
    static boolean isSupported() {
        return Build.VERSION.SDK_INT >= Build.VERSION_CODES.R;
    }

    static boolean isConnected() {
        return instance != null;
    }

    /**
     * Whether the user has switched the service on. {@link #isConnected()} can still be false for
     * a moment after this turns true, while the system binds the service.
     */
    static boolean isEnabled(Context context) {
        String enabled = Settings.Secure.getString(
            context.getContentResolver(), Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES);
        if (TextUtils.isEmpty(enabled)) return false;
        ComponentName component =
            new ComponentName(context, ScreenCaptureAccessibilityService.class);
        return enabled.contains(component.flattenToString())
            || enabled.contains(component.flattenToShortString());
    }

    static void capture(Callback callback) {
        capture(callback, 1);
    }

    private static void capture(final Callback callback, final int retriesLeft) {
        if (!isSupported()) {
            callback.onResult(null, "Accessibility capture needs Android 11 (API 30) or newer");
            return;
        }
        final ScreenCaptureAccessibilityService service = instance;
        if (service == null) {
            callback.onResult(null,
                "Accessibility service is not connected. Enable it in Settings > Accessibility.");
            return;
        }
        takeScreenshot(service, callback, retriesLeft);
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private static void takeScreenshot(final ScreenCaptureAccessibilityService service,
                                       final Callback callback, final int retriesLeft) {
        service.takeScreenshot(
            Display.DEFAULT_DISPLAY,
            CAPTURE_EXECUTOR,
            new AccessibilityService.TakeScreenshotCallback() {
                @Override
                public void onSuccess(AccessibilityService.ScreenshotResult result) {
                    Bitmap bitmap = null;
                    String error = null;
                    HardwareBuffer buffer = result.getHardwareBuffer();
                    try {
                        Bitmap hardware = Bitmap.wrapHardwareBuffer(buffer, result.getColorSpace());
                        if (hardware == null) {
                            error = "Could not wrap the screenshot buffer";
                        } else {
                            // The hardware bitmap dies with the buffer and cannot be scaled or
                            // re-encoded, so it has to be copied out before the buffer closes.
                            bitmap = hardware.copy(Bitmap.Config.ARGB_8888, false);
                            hardware.recycle();
                            if (bitmap == null) error = "Could not copy the screenshot buffer";
                        }
                    } catch (Throwable t) {
                        error = String.valueOf(t.getMessage());
                    } finally {
                        buffer.close();
                    }
                    // Deliberately outside the guarded block. The callback settles a Promise;
                    // if something downstream threw, the catch above would settle it a second
                    // time, which is a worse failure than letting the throw propagate.
                    callback.onResult(bitmap, error);
                }

                @Override
                public void onFailure(int errorCode) {
                    // The platform rate-limits these (~333ms in AOSP). Back off once rather than
                    // hardcoding a throttle, since the interval is not part of the contract.
                    if (errorCode == AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT
                        && retriesLeft > 0) {
                        new Handler(Looper.getMainLooper()).postDelayed(new Runnable() {
                            @Override
                            public void run() {
                                capture(callback, retriesLeft - 1);
                            }
                        }, RETRY_DELAY_MS);
                        return;
                    }
                    callback.onResult(null, describeError(errorCode));
                }
            });
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private static String describeError(int errorCode) {
        switch (errorCode) {
            case AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERNAL_ERROR:
                return "Screenshot failed: internal error";
            case AccessibilityService.ERROR_TAKE_SCREENSHOT_NO_ACCESSIBILITY_ACCESS:
                return "Screenshot failed: the service is missing android:canTakeScreenshot=\"true\"";
            case AccessibilityService.ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT:
                return "Screenshot failed: requests are coming in too fast";
            case AccessibilityService.ERROR_TAKE_SCREENSHOT_INVALID_DISPLAY:
                return "Screenshot failed: invalid display";
            default:
                return "Screenshot failed with error code " + errorCode;
        }
    }
}
