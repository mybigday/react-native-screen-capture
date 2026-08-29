package com.fugood.screencapture;

import android.app.Activity;
import android.content.Context;
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
import java.util.concurrent.atomic.AtomicBoolean;
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
 *
 * <p>Also holds the status-bar geometry shared with {@code accessibility} mode, which captures
 * the whole display and so has no window of its own to measure.
 */
final class WindowCapture {

    private static final Handler UI = new Handler(Looper.getMainLooper());

    /** How long to wait for the post-overlay frame on API < 29, where there is no commit callback. */
    private static final long FRAME_FALLBACK_DELAY_MS = 32L;

    /** Deadline for the API 29+ frame-commit callback, which is not guaranteed to fire. */
    private static final long FRAME_COMMIT_TIMEOUT_MS = 250L;

    /** Deadline for the per-surface copies, which can also be dropped without a callback. */
    private static final long SURFACE_COPY_TIMEOUT_MS = 1500L;

    /** Deadline for the whole-window read-back, for the same reason. */
    private static final long WINDOW_COPY_TIMEOUT_MS = 2000L;

    private WindowCapture() {
    }

    static void capture(final Activity activity, final boolean excludeStatusBar,
                        final CaptureCallback rawCallback) {
        // Every path below settles through this, so a throw escaping a callback cannot come back
        // round through a catch and settle the Promise a second time.
        final CaptureCallback callback = once(rawCallback);
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

    /** Wraps a callback so only the first settle gets through; later bitmaps are recycled. */
    static CaptureCallback once(final CaptureCallback delegate) {
        final AtomicBoolean settled = new AtomicBoolean(false);
        return new CaptureCallback() {
            @Override
            public void onResult(@Nullable Bitmap bitmap, @Nullable String error) {
                if (settled.compareAndSet(false, true)) {
                    delegate.onResult(bitmap, error);
                } else if (bitmap != null) {
                    bitmap.recycle();
                }
            }
        };
    }

    private static void captureOnUiThread(final Activity activity, final boolean excludeStatusBar,
                                          final CaptureCallback callback) {
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

        // Everything from here runs from Handler callbacks, i.e. outside capture()'s try. An
        // uncaught throw there would crash the main thread and leave the overlays installed.
        copySurfaceViews(surfaceViews, overlays, new Runnable() {
            @Override
            public void run() {
                try {
                    afterNextFrame(decor, new Runnable() {
                        @Override
                        public void run() {
                            try {
                                captureWindow(activity, window, decor, excludeStatusBar,
                                    overlays, callback);
                            } catch (Throwable t) {
                                removeOverlays(overlays);
                                callback.onResult(null, String.valueOf(t.getMessage()));
                            }
                        }
                    });
                } catch (Throwable t) {
                    removeOverlays(overlays);
                    callback.onResult(null, String.valueOf(t.getMessage()));
                }
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
        final AtomicBoolean finished = new AtomicBoolean(false);
        final Runnable finish = new Runnable() {
            @Override
            public void run() {
                if (!finished.compareAndSet(false, true)) return;
                // Drop the deadline below so it stops holding the capture closure -- and the
                // activity behind it -- alive on the normal path.
                UI.removeCallbacks(this);
                done.run();
            }
        };
        final Runnable countDown = new Runnable() {
            @Override
            public void run() {
                if (pending.decrementAndGet() == 0) finish.run();
            }
        };

        // Posted before the loop, not after: a loop that finishes synchronously -- every view
        // skipped or failing to allocate -- would otherwise run `finish` inline, remove nothing,
        // and then have this deadline posted behind it, pinning the whole capture closure for
        // another 1.5s after the Promise had already settled.
        //
        // The framework can also accept a request and then drop it -- a surface destroyed
        // mid-capture, for instance -- without ever calling the listener. Without a deadline
        // that would hang the capture forever with frozen overlays left on screen.
        UI.postDelayed(finish, SURFACE_COPY_TIMEOUT_MS);

        for (final SurfaceView view : views) {
            final int width = view.getWidth();
            final int height = view.getHeight();
            if (width <= 0 || height <= 0) {
                countDown.run();
                continue;
            }
            Bitmap allocated = null;
            try {
                // Inside the try: allocating a full-size ARGB_8888 buffer for a large surface is
                // itself a place this can fail.
                allocated = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                final Bitmap bitmap = allocated;
                PixelCopy.request(view, bitmap, new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override
                    public void onPixelCopyFinished(int copyResult) {
                        // A copy that lands after the deadline below must not install an overlay
                        // nobody is going to remove.
                        if (copyResult != PixelCopy.SUCCESS || finished.get()) {
                            // Secure or DRM-protected surfaces land here too; the hole stays
                            // transparent.
                            bitmap.recycle();
                        } else {
                            BitmapDrawable drawable = new BitmapDrawable(view.getResources(), bitmap);
                            drawable.setBounds(0, 0, width, height);
                            view.getOverlay().add(drawable);
                            overlays.add(new Overlay(view, drawable, bitmap));
                        }
                        countDown.run();
                    }
                }, UI);
            } catch (Throwable t) {
                // Surface not created yet, or the allocation failed. Either way this view has to
                // count down: otherwise the window is never read back and the overlays installed
                // so far are never removed.
                if (allocated != null) allocated.recycle();
                countDown.run();
            }
        }
    }

    /** Runs {@code action} once the overlays we just added have actually reached the surface. */
    private static void afterNextFrame(final View decor, final Runnable action) {
        decor.invalidate();
        // A window that has stopped drawing never commits, and a detached decor never runs what
        // View.post() queued -- ViewRootImpl holds it until re-attach. Either way, without a
        // deadline the capture would hang forever with the overlays still installed.
        final AtomicBoolean done = new AtomicBoolean(false);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Holds the registered callback so the deadline can take it back off the observer:
            // frame-commit callbacks are only dropped when they fire, and this one retains the
            // whole capture closure -- activity, decor, overlays, Promise -- until it does.
            final Runnable[] committed = new Runnable[1];
            final Runnable guarded = new Runnable() {
                @Override
                public void run() {
                    if (!done.compareAndSet(false, true)) return;
                    UI.removeCallbacks(this);
                    if (committed[0] != null) {
                        decor.getViewTreeObserver().unregisterFrameCommitCallback(committed[0]);
                    }
                    action.run();
                }
            };
            committed[0] = new Runnable() {
                @Override
                public void run() {
                    UI.post(guarded);
                }
            };
            decor.getViewTreeObserver().registerFrameCommitCallback(committed[0]);
            UI.postDelayed(guarded, FRAME_COMMIT_TIMEOUT_MS);
        } else {
            // View.post() on a detached decor is held by ViewRootImpl until re-attach, which
            // may never come -- and there is no API to take it back. So the queued runnable
            // reaches `guarded` through a slot the deadline can empty, and what it would have
            // pinned (activity, decor, overlays, Promise) is released either way.
            final Runnable[] pending = new Runnable[1];
            final Runnable guarded = new Runnable() {
                @Override
                public void run() {
                    if (!done.compareAndSet(false, true)) return;
                    UI.removeCallbacks(this);
                    pending[0] = null;
                    action.run();
                }
            };
            pending[0] = guarded;
            decor.post(new Runnable() {
                @Override
                public void run() {
                    Runnable next = pending[0];
                    if (next != null) UI.postDelayed(next, FRAME_FALLBACK_DELAY_MS);
                }
            });
            UI.postDelayed(guarded, FRAME_COMMIT_TIMEOUT_MS + FRAME_FALLBACK_DELAY_MS);
        }
    }

    private static void captureWindow(final Activity activity, final Window window, final View decor,
                                      final boolean excludeStatusBar, final List<Overlay> overlays,
                                      final CaptureCallback callback) {
        final int width = decor.getWidth();
        final int height = decor.getHeight();
        int offset = excludeStatusBar ? windowStatusBarHeight(activity, decor) : 0;
        if (offset < 0 || offset >= height) offset = 0;
        final int top = offset;
        final int outHeight = height - top;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            final Bitmap out = Bitmap.createBitmap(width, outHeight, Bitmap.Config.ARGB_8888);
            // Same hazard as the two hops before it: a window whose surface is destroyed
            // between the request and the copy leaves the listener uncalled, and this listener
            // is the only thing that takes the overlays back off the SurfaceViews. Without a
            // deadline the user is left looking at frozen stills over live video.
            final Runnable deadline = new Runnable() {
                @Override
                public void run() {
                    removeOverlays(overlays);
                    callback.onResult(null, "PixelCopy did not report a result in time");
                }
            };
            try {
                PixelCopy.request(window, new Rect(0, top, width, height), out,
                    new PixelCopy.OnPixelCopyFinishedListener() {
                        @Override
                        public void onPixelCopyFinished(int copyResult) {
                            UI.removeCallbacks(deadline);
                            removeOverlays(overlays);
                            // A copy that lands after the deadline settles through once(),
                            // which drops it and recycles the bitmap.
                            if (copyResult == PixelCopy.SUCCESS) {
                                callback.onResult(out, null);
                            } else {
                                out.recycle();
                                callback.onResult(null, "PixelCopy failed with code " + copyResult);
                            }
                        }
                    }, UI);
                UI.postDelayed(deadline, WINDOW_COPY_TIMEOUT_MS);
            } catch (IllegalArgumentException e) {
                UI.removeCallbacks(deadline);
                removeOverlays(overlays);
                out.recycle();
                callback.onResult(null, String.valueOf(e.getMessage()));
            }
            return;
        }

        // API 24-25: PixelCopy has no Window overload. Draw the hierarchy instead. The surface
        // content is still included because it is sitting in a ViewOverlay at this point.
        Bitmap out = null;
        String failure = null;
        Bitmap full = null;
        try {
            full = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            decor.draw(new Canvas(full));
            out = cropTop(full, top);
            full = null; // cropTop owns it now, and may already have recycled it
        } catch (Throwable t) {
            if (full != null) full.recycle();
            failure = String.valueOf(t.getMessage());
        } finally {
            removeOverlays(overlays);
        }
        // Outside the try: settling twice would be worse than letting a callback throw.
        callback.onResult(out, failure);
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
    private static int windowStatusBarHeight(final Activity activity, final View decor) {
        WindowInsets insets = decor.getRootWindowInsets();
        if (insets != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                return insets.getInsets(WindowInsets.Type.statusBars()).top;
            }
            return insets.getSystemWindowInsetTop();
        }
        return nominalStatusBarHeight(activity);
    }

    /**
     * Status bar height of the display, for cropping a whole-display capture.
     *
     * <p>Deliberately the platform's {@code status_bar_height} rather than this app's window
     * inset: {@code accessibility} mode captures the display, usually while a *different* app is
     * foreground, so our own window's inset describes the wrong thing (and is 0 outright when we
     * are immersive or in the bottom half of a split screen). This is the height the system gives
     * the bar; if the foreground app hides it there is nothing to crop and the option will take
     * real content instead -- documented in the README.
     *
     * <p>Not named {@code statusBarHeight}: an {@code Activity} is a {@code Context}, so an
     * overload would silently resolve here at any call site that meant the insets-aware
     * {@link #windowStatusBarHeight(Activity, View)}.
     */
    static int nominalStatusBarHeight(final Context context) {
        int id = context.getResources().getIdentifier("status_bar_height", "dimen", "android");
        return id > 0 ? context.getResources().getDimensionPixelSize(id) : 0;
    }

    /**
     * Drops {@code top} rows off a bitmap, recycling the original. Returns it unchanged at 0.
     *
     * <p>{@code createBitmap} hands back the source itself for a full-extent subset of an
     * immutable bitmap, so the identity check stays even though the guard above makes it
     * unreachable from here -- a future caller with different bounds would otherwise get a
     * recycled bitmap back.
     */
    static Bitmap cropTop(final Bitmap source, final int top) {
        if (top <= 0 || top >= source.getHeight()) return source;
        Bitmap cropped =
            Bitmap.createBitmap(source, 0, top, source.getWidth(), source.getHeight() - top);
        if (cropped != source) source.recycle();
        return cropped;
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
