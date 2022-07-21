package com.lewin.capture;

import android.app.Activity;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Rect;
import android.util.DisplayMetrics;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;
import android.view.PixelCopy;
import android.view.ViewGroup;
import android.view.SurfaceView;
import android.os.Handler;
import android.os.Looper;
import android.os.Build;

import java.util.List;
import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

public class ScreenUtils
{
    private ScreenUtils()
    {
        /* cannot be instantiated */
        throw new UnsupportedOperationException("cannot be instantiated");
    }

    /**
     * 获得屏幕宽度
     *
     * @param context
     * @return
     */
    public static int getScreenWidth(Context context)
    {
        WindowManager wm = (WindowManager) context
                .getSystemService(Context.WINDOW_SERVICE);
        DisplayMetrics outMetrics = new DisplayMetrics();
        wm.getDefaultDisplay().getMetrics(outMetrics);
        return outMetrics.widthPixels;
    }

    /**
     * 获得屏幕高度
     *
     * @param context
     * @return
     */
    public static int getScreenHeight(Context context)
    {
        WindowManager wm = (WindowManager) context
                .getSystemService(Context.WINDOW_SERVICE);
        DisplayMetrics outMetrics = new DisplayMetrics();
        wm.getDefaultDisplay().getMetrics(outMetrics);
        return outMetrics.heightPixels;
    }

    /**
     * 获得状态栏的高度
     *
     * @param context
     * @return
     */
    public static int getStatusHeight(Context context)
    {

        int statusHeight = -1;
        try
        {
            Class<?> clazz = Class.forName("com.android.internal.R$dimen.xml");
            Object object = clazz.newInstance();
            int height = Integer.parseInt(clazz.getField("status_bar_height")
                    .get(object).toString());
            statusHeight = context.getResources().getDimensionPixelSize(height);
        } catch (Exception e)
        {
            e.printStackTrace();
        }
        return statusHeight;
    }

    private static List<View> getAllChildren(final View v)
    {
        if (!(v instanceof ViewGroup)) {
            ArrayList<View> viewArrayList = new ArrayList<>();
            viewArrayList.add(v);
            return viewArrayList;
        }
        ArrayList<View> result = new ArrayList<>();
        ViewGroup viewGroup = (ViewGroup) v;
        for (int i = 0; i < viewGroup.getChildCount(); i++) {
            View child = viewGroup.getChildAt(i);
            result.addAll(getAllChildren(child));
        }
        return result;
    }

    private static void captureChildSurfaceView(
        final View rootView,
        final Bitmap windowBitmap,
        final int cropHeight,
        final CaptureCallback callback
    )
    {
        List<View> childrenList = getAllChildren(rootView);
        if (childrenList.size() == 0) {
            callback.invoke(windowBitmap);
            return;
        }
        final Bitmap result = Bitmap.createBitmap(windowBitmap.getWidth(), windowBitmap.getHeight(), Bitmap.Config.ARGB_8888);

        Canvas canvas = new Canvas(result);
        canvas.drawBitmap(windowBitmap, 0f, 0f, null);
        windowBitmap.recycle();

        for (final View child : childrenList) {
            if (child instanceof SurfaceView) {
                final SurfaceView svChild = (SurfaceView) child;
                final Bitmap surfaceBitmap = Bitmap.createBitmap(svChild.getWidth(), svChild.getHeight(), Bitmap.Config.ARGB_8888);
                try {
                    final CountDownLatch latch = new CountDownLatch(1);
                    PixelCopy.request(svChild, surfaceBitmap, new PixelCopy.OnPixelCopyFinishedListener() {
                        @Override
                        public void onPixelCopyFinished(int copyResult) {
                            if (copyResult == PixelCopy.SUCCESS) {
                                int[] point = new int[2];
                                svChild.getLocationInWindow(point);
                                int x = point[0];
                                int y = point[1];
                                canvas.drawBitmap(surfaceBitmap, x, y - cropHeight, null);
                            }
                            latch.countDown();
                        }
                    }, new Handler(Looper.getMainLooper()));
                    latch.await(5, TimeUnit.SECONDS);
                } catch (Exception e) {
                }
            }
        }
        callback.invoke(result);
    }

    /**
     * 获取当前屏幕截图，包含状态栏
     *
     * @param activity
     * @param callback
     * @return
     */
    public static void snapShotWithStatusBar(Activity activity, final CaptureCallback callback)
    {
        Window window = activity.getWindow();
        final View view = window.getDecorView();
        final int width = getScreenWidth(activity);
        final int height = getScreenHeight(activity);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Rect rect = new Rect(
                0,
                0,
                width,
                height
            );
            final Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            PixelCopy.request(
                window,
                rect,
                bitmap,
                new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override
                    public void onPixelCopyFinished(int copyResult) {
                        if (copyResult == PixelCopy.SUCCESS) {
                            // Create new thread to avoid count down latch blocking the UI thread
                            new Thread() {
                                @Override
                                public void run() {
                                    captureChildSurfaceView(view, bitmap, 0, callback);
                                }
                            }.start();
                        } else {
                            callback.invoke(null);
                        }
                    }
                },
                new Handler(Looper.getMainLooper())
            );
        } else {
            view.setDrawingCacheEnabled(true);
            view.buildDrawingCache();
            Bitmap bmp = view.getDrawingCache();
            Bitmap bp = null;
            bp = Bitmap.createBitmap(bmp, 0, 0, width, height);
            view.destroyDrawingCache();
            callback.invoke(bp);
        }

    }

    /**
     * 获取当前屏幕截图，不包含状态栏
     *
     * @param activity
     * @param callback
     * @return
     */
    public static void snapShotWithoutStatusBar(Activity activity, final CaptureCallback callback)
    {
        Window window = activity.getWindow();
        View view = window.getDecorView();
        final int statusBarHeight = getStatusHeight(activity);
        int width = getScreenWidth(activity);
        int height = getScreenHeight(activity);

        if (Build.VERSION.SDK_INT >= 24) {
            Rect rect = new Rect(
                0,
                statusBarHeight,
                width,
                height
            );
            final Bitmap bitmap = Bitmap.createBitmap(width, height - statusBarHeight, Bitmap.Config.ARGB_8888);
            PixelCopy.request(
                window,
                rect,
                bitmap,
                new PixelCopy.OnPixelCopyFinishedListener() {
                    @Override
                    public void onPixelCopyFinished(int copyResult) {
                        if (copyResult == PixelCopy.SUCCESS) {
                            // Create new thread to avoid count down latch blocking the UI thread
                            new Thread() {
                                @Override
                                public void run() {
                                    captureChildSurfaceView(view, bitmap, statusBarHeight, callback);
                                }
                            }.start();
                        } else {
                            callback.invoke(null);
                        }
                    }
                },
                new Handler(Looper.getMainLooper())
            );
        } else {
            view.setDrawingCacheEnabled(true);
            view.buildDrawingCache();
            Bitmap bmp = view.getDrawingCache();
            Bitmap bp = null;
            bp = Bitmap.createBitmap(bmp, 0, statusBarHeight , width, height
                    - statusBarHeight);
            view.destroyDrawingCache();
            callback.invoke(bp);
        }

    }

    public static int getStatusHeight(Activity context) {
        int result = 0;
        int resourceId = context.getResources().getIdentifier("status_bar_height", "dimen", "android");
        if (resourceId > 0) {
            result = context.getResources().getDimensionPixelSize(resourceId);
        }
        return result;
    }

}
