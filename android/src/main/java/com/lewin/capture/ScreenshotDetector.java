package com.lewin.capture;

import android.app.Activity;
import android.content.Context;
import android.os.Build;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

/**
 * Notifies when <em>the user</em> takes a screenshot.
 *
 * <p>API 34+ uses {@link Activity#registerScreenCaptureCallback}, which is the supported route.
 * It does not hand over an image -- but this module can take its own screenshot in response,
 * which closes the loop.
 *
 * <p>Below API 34 the only option is watching MediaStore for a new file whose name looks like a
 * screenshot. That is unreliable under scoped storage and needs {@code READ_MEDIA_IMAGES}
 * (or {@code READ_EXTERNAL_STORAGE}), which the host app must declare itself.
 */
final class ScreenshotDetector {

    interface Listener {
        void onScreenshot(@Nullable String path);
    }

    private final Context context;

    @Nullable
    private Listener listener;
    @Nullable
    private ScreenCapturetListenManager legacyManager;
    @Nullable
    private Activity.ScreenCaptureCallback callback;
    @Nullable
    private Activity registeredActivity;

    ScreenshotDetector(Context context) {
        this.context = context;
    }

    boolean isRunning() {
        return listener != null;
    }

    void start(@Nullable Activity activity, Listener listener) {
        stop();
        this.listener = listener;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && activity != null) {
            startModern(activity);
        } else {
            startLegacy();
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private void startModern(Activity activity) {
        callback = new Activity.ScreenCaptureCallback() {
            @Override
            public void onScreenCaptured() {
                Listener current = listener;
                if (current != null) current.onScreenshot(null);
            }
        };
        // Throws SecurityException when the app has not declared DETECT_SCREEN_CAPTURE.
        activity.registerScreenCaptureCallback(activity.getMainExecutor(), callback);
        registeredActivity = activity;
    }

    private void startLegacy() {
        legacyManager = ScreenCapturetListenManager.newInstance(context, null);
        legacyManager.setListener(new ScreenCapturetListenManager.OnScreenCapturetListen() {
            @Override
            public void onShot(String imagePath) {
                Listener current = listener;
                if (current != null) current.onScreenshot(imagePath);
            }
        });
        legacyManager.startListen();
    }

    void stop() {
        listener = null;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE
            && registeredActivity != null && callback != null) {
            try {
                registeredActivity.unregisterScreenCaptureCallback(callback);
            } catch (Throwable ignored) {
                // Activity already gone.
            }
        }
        registeredActivity = null;
        callback = null;
        if (legacyManager != null) {
            legacyManager.stopListen();
            legacyManager = null;
        }
    }
}
