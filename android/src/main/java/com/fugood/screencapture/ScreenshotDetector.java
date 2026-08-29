/*
 * Notifies when *the user* takes a screenshot.
 */
package com.fugood.screencapture;

import android.app.Activity;
import android.os.Build;

import androidx.annotation.Nullable;
import androidx.annotation.RequiresApi;

import com.facebook.react.bridge.LifecycleEventListener;
import com.facebook.react.bridge.ReactApplicationContext;

import java.lang.ref.WeakReference;

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
 *
 * <p>The API 34 callback binds to one {@link Activity}, so this re-binds on every host resume:
 * otherwise a rotation silently ends detection and pins the destroyed activity in memory. It is
 * also how a detector that had to start on the legacy path -- because no activity existed yet --
 * upgrades once one does.
 *
 * <p>All of this touches main-thread-only APIs; callers are expected to be on the UI thread.
 */
final class ScreenshotDetector implements LifecycleEventListener {

    interface Listener {
        void onScreenshot(@Nullable String path);
    }

    private final ReactApplicationContext context;

    @Nullable
    private Listener listener;
    @Nullable
    private ScreenCapturetListenManager legacyManager;
    @Nullable
    private Activity.ScreenCaptureCallback callback;
    @Nullable
    private WeakReference<Activity> registeredActivity;

    ScreenshotDetector(ReactApplicationContext context) {
        this.context = context;
    }

    void start(Listener listener) {
        stop();
        this.listener = listener;
        context.addLifecycleEventListener(this);
        bind();
    }

    void stop() {
        if (listener != null) context.removeLifecycleEventListener(this);
        listener = null;
        unbind();
    }

    @Override
    public void onHostResume() {
        if (listener == null) return;
        Activity current = context.getCurrentActivity();
        boolean activityChanged = callback != null && registeredActivity != null
            && registeredActivity.get() != current;
        boolean canUpgrade = callback == null && legacyManager != null
            && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && current != null;
        if (activityChanged || canUpgrade) {
            unbind();
            bind();
        }
    }

    @Override
    public void onHostPause() {
    }

    @Override
    public void onHostDestroy() {
        unbind();
    }

    private void bind() {
        Activity activity = context.getCurrentActivity();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && activity != null) {
            bindModern(activity);
        } else {
            bindLegacy();
        }
    }

    @RequiresApi(Build.VERSION_CODES.UPSIDE_DOWN_CAKE)
    private void bindModern(final Activity activity) {
        callback = new Activity.ScreenCaptureCallback() {
            @Override
            public void onScreenCaptured() {
                Listener current = listener;
                if (current != null) current.onScreenshot(null);
            }
        };
        // Throws SecurityException when the app has not declared DETECT_SCREEN_CAPTURE.
        activity.registerScreenCaptureCallback(activity.getMainExecutor(), callback);
        registeredActivity = new WeakReference<>(activity);
    }

    private void bindLegacy() {
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

    private void unbind() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE && callback != null) {
            Activity activity = registeredActivity != null ? registeredActivity.get() : null;
            if (activity != null) {
                try {
                    activity.unregisterScreenCaptureCallback(callback);
                } catch (Throwable ignored) {
                    // Activity already gone.
                }
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
