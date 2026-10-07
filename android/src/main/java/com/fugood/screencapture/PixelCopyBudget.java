package com.fugood.screencapture;

/** Process-wide limit for destinations which PixelCopy can still write into. */
final class PixelCopyBudget {
    static final long MAX_PIXELS = 64_000_000L;
    private static long outstandingPixels;

    private PixelCopyBudget() {}

    static long pixels(int width, int height) {
        if (width <= 0 || height <= 0) throw new IllegalArgumentException("Invalid PixelCopy dimensions");
        long pixels = (long) width * height;
        if (pixels > MAX_PIXELS) throw new IllegalArgumentException("PixelCopy exceeds the pixel limit");
        return pixels;
    }

    static synchronized Lease acquire(int width, int height) {
        long pixels = pixels(width, height);
        if (pixels > MAX_PIXELS - outstandingPixels) {
            throw new IllegalStateException("Too many pending PixelCopy pixels");
        }
        // Construct before accounting: an allocation failure must not consume capacity.
        Lease lease = new Lease(pixels);
        outstandingPixels += pixels;
        return lease;
    }

    static final class Lease {
        private final long pixels;
        private boolean released;

        private Lease(long pixels) { this.pixels = pixels; }

        /** Only a native callback or synchronous rejection may release; never a deadline. */
        boolean release() {
            synchronized (PixelCopyBudget.class) {
                if (released) return false;
                released = true;
                outstandingPixels -= pixels;
                return true;
            }
        }
    }
}
