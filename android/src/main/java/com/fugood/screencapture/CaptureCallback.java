package com.fugood.screencapture;

import android.graphics.Bitmap;

import androidx.annotation.Nullable;

/**
 * Result of a capture, whichever mode produced it. Shared so the module can hand the same
 * callback to either backend instead of adapting between two identical interfaces.
 *
 * <p>Exactly one of {@code bitmap} and {@code error} is non-null.
 */
interface CaptureCallback {
    void onResult(@Nullable Bitmap bitmap, @Nullable String error);
}
