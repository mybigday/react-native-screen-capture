package com.fugood.screencapture;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.content.pm.PackageManager;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.hardware.display.DisplayManager;
import android.hardware.HardwareBuffer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;

import java.util.ArrayList;
import java.util.List;
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

    /**
     * Whether the host app actually declared this service.
     *
     * <p>The library's manifest deliberately does not: an accessibility service is a heavy,
     * user-visible permission that an app must opt into. Without this check the mode looks
     * available on any new enough OS, and {@code requestPermission} would send the user to a
     * Settings page that lists nothing to enable.
     */
    static boolean isDeclared(Context context) {
        ComponentName component =
            new ComponentName(context, ScreenCaptureAccessibilityService.class);
        try {
            context.getPackageManager().getServiceInfo(component, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    static void capture(CaptureCallback callback) {
        capture(callback, "all");
    }

    /**
     * Captures one display, or every display this device is driving, stitched side by side.
     *
     * <p>{@code screenSelector} is {@code all}, {@code main}, or a display id. Android shows
     * content on a secondary display through a {@code Presentation}, whose window an Activity
     * cannot reach -- so this, not the view path, is what sees an external screen.
     */
    static void capture(final CaptureCallback callback, final String screenSelector) {
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

        final int[] displays = resolveDisplays(service, screenSelector);
        if (displays.length == 0) {
            callback.onResult(null, "No display matches " + screenSelector);
            return;
        }
        captureDisplays(service, displays, 0, new ArrayList<Bitmap>(), callback);
    }

    private static int[] resolveDisplays(Context context, String screenSelector) {
        if (screenSelector == null || "main".equals(screenSelector)) {
            return new int[] { Display.DEFAULT_DISPLAY };
        }
        DisplayManager manager =
            (DisplayManager) context.getSystemService(Context.DISPLAY_SERVICE);
        Display[] all = manager != null ? manager.getDisplays() : null;
        if (all == null || all.length == 0) return new int[] { Display.DEFAULT_DISPLAY };

        if (!"all".equals(screenSelector)) {
            for (Display display : all) {
                if (String.valueOf(display.getDisplayId()).equals(screenSelector)) {
                    return new int[] { display.getDisplayId() };
                }
            }
            return new int[0];
        }

        // Default display first, so the stitched image starts with the built-in screen.
        int[] ids = new int[all.length];
        int next = 1;
        ids[0] = Display.DEFAULT_DISPLAY;
        for (Display display : all) {
            if (display.getDisplayId() == Display.DEFAULT_DISPLAY) continue;
            ids[next++] = display.getDisplayId();
        }
        return next == ids.length ? ids : java.util.Arrays.copyOf(ids, next);
    }

    /** One display at a time: the platform rate-limits these, and parallel calls just retry. */
    private static void captureDisplays(final ScreenCaptureAccessibilityService service,
                                        final int[] displays, final int index,
                                        final List<Bitmap> collected,
                                        final CaptureCallback callback) {
        if (index >= displays.length) {
            Bitmap stitched = stitch(collected);
            if (stitched == null) {
                callback.onResult(null, "Could not compose the captured displays");
            } else {
                callback.onResult(stitched, null);
            }
            return;
        }
        takeScreenshot(service, displays[index], 1, new CaptureCallback() {
            @Override
            public void onResult(@Nullable Bitmap bitmap, @Nullable String error) {
                if (bitmap == null) {
                    // A secondary display that will not yield is not worth failing the whole
                    // capture over; the built-in screen still has to come back.
                    if (displays[index] == Display.DEFAULT_DISPLAY) {
                        for (Bitmap done : collected) done.recycle();
                        callback.onResult(null, error);
                        return;
                    }
                } else {
                    collected.add(bitmap);
                }
                captureDisplays(service, displays, index + 1, collected, callback);
            }
        });
    }

    /** Side by side, left to right, on a canvas as tall as the tallest display. */
    @Nullable
    private static Bitmap stitch(List<Bitmap> parts) {
        if (parts.isEmpty()) return null;
        if (parts.size() == 1) return parts.get(0);

        int width = 0, height = 0;
        for (Bitmap part : parts) {
            width += part.getWidth();
            height = Math.max(height, part.getHeight());
        }
        Bitmap out;
        try {
            out = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        } catch (Throwable t) {
            for (Bitmap part : parts) part.recycle();
            return null;
        }
        Canvas canvas = new Canvas(out);
        int x = 0;
        for (Bitmap part : parts) {
            canvas.drawBitmap(part, x, 0, null);
            x += part.getWidth();
            part.recycle();
        }
        return out;
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private static void takeScreenshot(final ScreenCaptureAccessibilityService service,
                                       final int displayId, final int retriesLeft,
                                       final CaptureCallback callback) {
        service.takeScreenshot(
            displayId,
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
                            try {
                                // The hardware bitmap dies with the buffer and cannot be scaled
                                // or re-encoded, so it has to be copied out before the buffer
                                // closes. Copying a full display costs ~18MB and can throw; the
                                // recycle belongs in a finally or the wrapper outlives it,
                                // holding a reference to a buffer that is about to be closed.
                                bitmap = hardware.copy(Bitmap.Config.ARGB_8888, false);
                            } finally {
                                hardware.recycle();
                            }
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
                                // Retry this display, not the whole selection.
                                takeScreenshot(service, displayId, retriesLeft - 1, callback);
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
