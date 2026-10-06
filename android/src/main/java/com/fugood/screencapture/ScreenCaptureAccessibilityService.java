package com.fugood.screencapture;

import android.accessibilityservice.AccessibilityService;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.hardware.HardwareBuffer;
import android.hardware.display.DisplayManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.view.Display;
import android.view.accessibility.AccessibilityEvent;
import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executor;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicBoolean;

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
        // Sized for every enumerated display *plus* the default one: getDisplays() is not
        // contractually obliged to include it, and if it does not, the loop below would run off
        // the end of an array sized to all.length.
        int[] ids = new int[all.length + 1];
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
        new DisplayCapture(service, displays, collected, callback).capture(index);
    }

    /** Owns collected frames until the final callback takes ownership of the result. */
    private static final class DisplayCapture {
        private final ScreenCaptureAccessibilityService service;
        private final int[] displays;
        private final List<Bitmap> collected;
        private final CaptureCallback callback;
        private final AtomicBoolean delivered = new AtomicBoolean();

        DisplayCapture(ScreenCaptureAccessibilityService service, int[] displays,
                       List<Bitmap> collected, CaptureCallback callback) {
            this.service = service;
            this.displays = displays;
            this.collected = collected;
            this.callback = callback;
        }

        void capture(final int index) {
            if (delivered.get()) return;
            Bitmap output = null;
            try {
                if (index >= displays.length) {
                    output = stitch(collected);
                    collected.clear();
                    deliver(output, output == null ? "Could not compose the captured displays" : null);
                    return;
                }
                takeScreenshot(service, displays[index], 1, (bitmap, error) -> accept(index, bitmap, error));
            } catch (Throwable failure) {
                // A downstream callback may already have handed the bitmap to the encoder before
                // throwing. It owns cleanup from that point; never recycle or settle again here.
                if (delivered.get()) throw failure;
                recycle(output);
                fail(String.valueOf(failure.getMessage()));
            }
        }

        private void accept(int index, Bitmap bitmap, String error) {
            if (delivered.get()) {
                recycle(bitmap);
                return;
            }
            try {
                if (bitmap == null && displays[index] == Display.DEFAULT_DISPLAY) {
                    fail(error);
                    return;
                }
                // An unavailable secondary display still allows the other displays to return.
                if (bitmap != null) {
                    collected.add(bitmap);
                    long pixels = 0;
                    for (Bitmap part : collected)
                        pixels += (long)part.getWidth() * part.getHeight();
                    if (pixels > 64000000) {
                        throw new IllegalArgumentException("Captured displays exceed 64 megapixels");
                    }
                }
                capture(index + 1);
            } catch (Throwable failure) {
                if (delivered.get()) throw failure;
                // add() can fail before or after adding: isRecycled protects both ownership cases.
                recycle(bitmap);
                fail(String.valueOf(failure.getMessage()));
            }
        }

        private void fail(String error) {
            for (Bitmap part : collected) recycle(part);
            collected.clear();
            deliver(null, error);
        }

        private void deliver(Bitmap bitmap, String error) {
            if (!delivered.compareAndSet(false, true)) {
                recycle(bitmap);
                return;
            }
            callback.onResult(bitmap, error);
        }

        private static void recycle(Bitmap bitmap) {
            if (bitmap != null && !bitmap.isRecycled()) bitmap.recycle();
        }
    }

    /** Side by side, left to right, on a canvas as tall as the tallest display. */
    @Nullable
    private static Bitmap stitch(List<Bitmap> parts) {
        if (parts.isEmpty()) return null;
        if (parts.size() == 1) return parts.get(0);

        Bitmap out = null;
        try {
            long width = 0;
            int height = 0;
            for (Bitmap part : parts) {
                width += part.getWidth();
                height = Math.max(height, part.getHeight());
            }
            if (width > Integer.MAX_VALUE)
                throw new IllegalArgumentException("Display width overflow");
            CaptureFiles.scaledSize((int)width, height, 1);
            out = Bitmap.createBitmap((int)width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(out);
            int x = 0;
            for (Bitmap part : parts) {
                canvas.drawBitmap(part, x, 0, null);
                x += part.getWidth();
            }
            return out;
        } catch (Throwable error) {
            if (out != null)
                out.recycle();
            return null;
        } finally {
            for (Bitmap part : parts)
                if (!part.isRecycled())
                    part.recycle();
        }
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private static void takeScreenshot(final ScreenCaptureAccessibilityService service,
                                       final int displayId, final int retriesLeft,
                                       final CaptureCallback callback) {
        new ScreenshotRequest(service, displayId, callback).start(retriesLeft);
    }

    @RequiresApi(Build.VERSION_CODES.R)
    private static final class ScreenshotRequest {
        private final ScreenCaptureAccessibilityService service;
        private final int display;
        private final CaptureCallback callback;
        private final AtomicBoolean terminal = new AtomicBoolean();
        private final Handler handler = new Handler(Looper.getMainLooper());
        private final Runnable timeout = () -> finish(null, "Screenshot callback timed out");
        private Runnable retry;

        ScreenshotRequest(ScreenCaptureAccessibilityService service, int display,
                          CaptureCallback callback) {
            this.service = service;
            this.display = display;
            this.callback = callback;
            handler.postDelayed(timeout, 3000);
        }

        private void cancelTimers() {
            handler.removeCallbacks(timeout);
            synchronized (this) {
                if (retry != null)
                    handler.removeCallbacks(retry);
                retry = null;
            }
        }

        private void finish(Bitmap bitmap, String error) {
            if (!terminal.compareAndSet(false, true)) {
                if (bitmap != null)
                    bitmap.recycle();
                return;
            }
            cancelTimers();
            callback.onResult(bitmap, error);
        }

        void start(final int retriesLeft) {
            if (terminal.get())
                return;
            if (instance != service) {
                finish(null, "Accessibility service disconnected");
                return;
            }
            try {
                service.takeScreenshot(
                    display, CAPTURE_EXECUTOR, new AccessibilityService.TakeScreenshotCallback() {
                        @Override
                        public void onSuccess(AccessibilityService.ScreenshotResult result) {
                            // Claim before copying. Timeout cannot release admission during a large
                            // copy.
                            boolean claimed = terminal.compareAndSet(false, true);
                            if (claimed)
                                cancelTimers();
                            HardwareBuffer buffer = null;
                            Bitmap bitmap = null;
                            String error = null;
                            try {
                                buffer = result.getHardwareBuffer();
                                if (claimed) {
                                    Bitmap hardware =
                                        Bitmap.wrapHardwareBuffer(buffer, result.getColorSpace());
                                    if (hardware == null)
                                        error = "Could not wrap the screenshot buffer";
                                    else {
                                        try {
                                            CaptureFiles.scaledSize(hardware.getWidth(),
                                                                    hardware.getHeight(), 1);
                                            bitmap = hardware.copy(Bitmap.Config.ARGB_8888, false);
                                            if (bitmap == null)
                                                error = "Could not copy the screenshot buffer";
                                        } finally {
                                            hardware.recycle();
                                        }
                                    }
                                }
                            } catch (Throwable failure) {
                                if (bitmap != null) {
                                    bitmap.recycle();
                                    bitmap = null;
                                }
                                error = String.valueOf(failure.getMessage());
                            } finally {
                                if (buffer != null) {
                                    try {
                                        buffer.close();
                                    } catch (Throwable failure) {
                                        if (bitmap != null) {
                                            bitmap.recycle();
                                            bitmap = null;
                                        }
                                        error = String.valueOf(failure.getMessage());
                                    }
                                }
                            }
                            // A late success closes its buffer without copying or delivering again.
                            if (claimed)
                                callback.onResult(bitmap, error);
                        }

                        @Override
                        public void onFailure(int errorCode) {
                            if (terminal.get())
                                return;
                            if (errorCode == AccessibilityService
                                                 .ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT &&
                                retriesLeft > 0) {
                                synchronized (ScreenshotRequest.this) {
                                    if (terminal.get())
                                        return;
                                    retry = () -> start(retriesLeft - 1);
                                    handler.postDelayed(retry, RETRY_DELAY_MS);
                                }
                            } else
                                finish(null, describeError(errorCode));
                        }
                    });
            } catch (Throwable error) {
                finish(null, String.valueOf(error.getMessage()));
            }
        }
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
