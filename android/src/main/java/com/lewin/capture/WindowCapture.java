package com.lewin.capture;

import android.app.Activity;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.graphics.drawable.BitmapDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.PixelCopy;
import android.view.SurfaceView;
import android.view.TextureView;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowInsets;

import androidx.annotation.Nullable;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Captures the current activity window, including any {@link SurfaceView} content
 * (video players, camera previews, WebRTC renderers).
 *
 * <p>A {@code SurfaceView} lives on its own surface and punches a transparent hole in the
 * window layer, so a plain window readback never contains it. Rather than copying each
 * surface separately and pasting it back afterwards -- which loses z-order, clipping and
 * transforms -- we copy each surface, install the result as a {@link android.view.ViewOverlay}
 * on that same {@code SurfaceView}, and then do a single window readback. The overlay is
 * painted by the view system into the window surface, so it lands in the right place, behind
 * whatever covers it, clipped exactly like the view itself.
 *
 * <p>{@link TextureView} needs no special handling: it draws through the view hierarchy and
 * is already present in the window readback.
 */
final class WindowCapture {

    interface Callback {
        void onResult(@Nullable Bitmap bitmap, @Nullable String error);
    }

    private static final Handler UI = new Handler(Looper.getMainLooper());

    /** How long to wait for the post-overlay frame on API < 29, where there is no commit callback. */
    private static final long FRAME_FALLBACK_DELAY_MS = 32L;

    private WindowCapture() {
    }

    static void capture(final Activity activity, final boolean excludeStatusBar, final Callback callback) {
        if (activity == null) {
            callback.onResult(null, "No current activity");
            return;
        }
        UI.post(new Runnable() {
            @Override
            public void run() {
                try {
                    captureOnUiThread(activity, excludeStatusBar, callback);
                } catch (Throwable t) {
                    callback.onResult(null, String.valueOf(t.getMessage()));
                }
            }
        });
    }

    private static void captureOnUiThread(final Activity activity, final boolean excludeStatusBar,
                                          final Callback callback) {
        final Window window = activity.getWindow();
        if (window == null) {
            callback.onResult(null, "Activity has no window");
            return;
        }
        final View decor = window.getDecorView();
        if (decor.getWidth() <= 0 || decor.getHeight() <= 0) {
            callback.onResult(null, "Window has not been laid out yet");
            return;
        }

        final List<SurfaceView> surfaceViews = new ArrayList<>();
        collectSurfaceViews(decor, surfaceViews);

        final List<Overlay> overlays = new ArrayList<>();
        if (surfaceViews.isEmpty()) {
            captureWindow(activity, window, decor, excludeStatusBar, overlays, callback);
            return;
        }

        copySurfaceViews(surfaceViews, overlays, new Runnable() {
            @Override
            public void run() {
                afterNextFrame(decor, new Runnable() {
                    @Override
                    public void run() {
                        captureWindow(activity, window, decor, excludeStatusBar, overlays, callback);
                    }
                });
            }
        });
    }

    /**
     * Issues every {@link PixelCopy} request at once and installs each successful result as an
     * overlay. The previous implementation did this serially with a 5s latch per view, so N
     * SurfaceViews had a worst case of N x 5s.
     */
    private static void copySurfaceViews(final List<SurfaceView> views, final List<Overlay> overlays,
                                         final Runnable done) {
        final AtomicInteger pending = new AtomicInteger(views.size());
        for (final SurfaceView view : views) {
            final int width = view.getWidth();
            final int height = view.getHeight();
            if (width <= 0 || height <= 0) {
                if (pending.decrementAndGet() == 0) done.run();
                continue;
            }
            final Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            try {
                PixelCopy.request(view, bitmap, new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override
                    public void onPixelCopyFinished(int copyResult) {
                        if (copyResult == PixelCopy.SUCCESS) {
                            BitmapDrawable drawable = new BitmapDrawable(view.getResources(), bitmap);
                            drawable.setBounds(0, 0, width, height);
                            view.getOverlay().add(drawable);
                            overlays.add(new Overlay(view, drawable, bitmap));
                        } else {
                            // Secure or DRM-protected surfaces land here; the hole stays transparent.
                            bitmap.recycle();
                        }
                        if (pending.decrementAndGet() == 0) done.run();
                    }
                }, UI);
            } catch (IllegalArgumentException e) {
                // Surface not yet created.
                bitmap.recycle();
                if (pending.decrementAndGet() == 0) done.run();
            }
        }
    }

    /** Runs {@code action} once the overlays we just added have actually reached the surface. */
    private static void afterNextFrame(final View decor, final Runnable action) {
        decor.invalidate();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            decor.getViewTreeObserver().registerFrameCommitCallback(new Runnable() {
                @Override
                public void run() {
                    UI.post(action);
                }
            });
        } else {
            decor.post(new Runnable() {
                @Override
                public void run() {
                    UI.postDelayed(action, FRAME_FALLBACK_DELAY_MS);
                }
            });
        }
    }

    private static void captureWindow(final Activity activity, final Window window, final View decor,
                                      final boolean excludeStatusBar, final List<Overlay> overlays,
                                      final Callback callback) {
        final int width = decor.getWidth();
        final int height = decor.getHeight();
        int offset = excludeStatusBar ? statusBarHeight(activity, decor) : 0;
        if (offset < 0 || offset >= height) offset = 0;
        final int top = offset;
        final int outHeight = height - top;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            final Bitmap out = Bitmap.createBitmap(width, outHeight, Bitmap.Config.ARGB_8888);
            try {
                PixelCopy.request(window, new Rect(0, top, width, height), out,
                    new PixelCopy.OnPixelCopyFinishedListener() {
                        @Override
                        public void onPixelCopyFinished(int copyResult) {
                            removeOverlays(overlays);
                            if (copyResult == PixelCopy.SUCCESS) {
                                callback.onResult(out, null);
                            } else {
                                out.recycle();
                                callback.onResult(null, "PixelCopy failed with code " + copyResult);
                            }
                        }
                    }, UI);
            } catch (IllegalArgumentException e) {
                removeOverlays(overlays);
                out.recycle();
                callback.onResult(null, String.valueOf(e.getMessage()));
            }
            return;
        }

        // API 24-25: PixelCopy has no Window overload. Draw the hierarchy instead. The surface
        // content is still included because it is sitting in a ViewOverlay at this point.
        Bitmap full = null;
        try {
            full = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            decor.draw(new Canvas(full));
            Bitmap out = top > 0 ? Bitmap.createBitmap(full, 0, top, width, outHeight) : full;
            if (out != full) full.recycle();
            callback.onResult(out, null);
        } catch (Throwable t) {
            if (full != null) full.recycle();
            callback.onResult(null, String.valueOf(t.getMessage()));
        } finally {
            removeOverlays(overlays);
        }
    }

    private static void removeOverlays(final List<Overlay> overlays) {
        for (Overlay overlay : overlays) {
            overlay.view.getOverlay().remove(overlay.drawable);
            overlay.bitmap.recycle();
        }
        overlays.clear();
    }

    private static void collectSurfaceViews(final View view, final List<SurfaceView> out) {
        if (view.getVisibility() != View.VISIBLE) return;
        if (view instanceof SurfaceView) {
            out.add((SurfaceView) view);
            return;
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                collectSurfaceViews(group.getChildAt(i), out);
            }
        }
    }

    @SuppressWarnings("deprecation")
    private static int statusBarHeight(final Activity activity, final View decor) {
        WindowInsets insets = decor.getRootWindowInsets();
        if (insets != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return insets.getInsets(WindowInsets.Type.statusBars()).top;
            }
            return insets.getSystemWindowInsetTop();
        }
        int id = activity.getResources().getIdentifier("status_bar_height", "dimen", "android");
        return id > 0 ? activity.getResources().getDimensionPixelSize(id) : 0;
    }

    /** Dev helper backing {@code dumpHierarchy()}. */
    static String dump(final Activity activity) {
        if (activity == null || activity.getWindow() == null) return "<no activity>";
        StringBuilder sb = new StringBuilder();
        dump(activity.getWindow().getDecorView(), 0, sb);
        return sb.toString();
    }

    private static void dump(final View view, final int depth, final StringBuilder sb) {
        for (int i = 0; i < depth; i++) sb.append("  ");
        sb.append(view.getClass().getName())
            .append(" [").append(view.getWidth()).append('x').append(view.getHeight()).append(']');
        if (view instanceof SurfaceView) sb.append("  <- SurfaceView, captured via overlay");
        if (view instanceof TextureView) sb.append("  <- TextureView, captured directly");
        if (view.getVisibility() != View.VISIBLE) sb.append("  (not visible)");
        sb.append('\n');
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int i = 0; i < group.getChildCount(); i++) {
                dump(group.getChildAt(i), depth + 1, sb);
            }
        }
    }

    private static final class Overlay {
        final SurfaceView view;
        final BitmapDrawable drawable;
        final Bitmap bitmap;

        Overlay(SurfaceView view, BitmapDrawable drawable, Bitmap bitmap) {
            this.view = view;
            this.drawable = drawable;
            this.bitmap = bitmap;
        }
    }
}
