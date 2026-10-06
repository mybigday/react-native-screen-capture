package com.fugood.screencapture;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.URI;
import java.util.UUID;

/** Completed captures only, in a directory owned by this module. Call on the encoder. */
final class CaptureFiles {
    interface Writer {
        void write(OutputStream output) throws IOException;
    }
    interface IdentityChecker {
        /** Null means the path is absent; other IO errors must propagate. */
        Object pathKey(File file) throws IOException;
        Object openedKey(FileOutputStream output, File path) throws IOException;
    }
    private final File directory;
    private final IdentityChecker identity;

    CaptureFiles(File cache) { this(cache, null); }

    CaptureFiles(File cache, IdentityChecker identity) {
        directory = new File(cache, "react-native-screen-capture");
        this.identity = identity;
    }

    File publish(String extension, Writer writer) throws IOException {
        synchronized (CaptureFiles.class) { return publishLocked(extension, writer); }
    }

    private File publishLocked(String extension, Writer writer) throws IOException {
        if ((!directory.mkdirs() && !directory.isDirectory()) ||
            !directory.getCanonicalFile().equals(directory.getAbsoluteFile())) {
            throw new IOException("Capture cache is not a regular directory");
        }
        Object directoryKey = requiredPathKey(directory);
        File pending = File.createTempFile("CAPTURE-", ".pending", directory);
        File completed = new File(directory, "CAPTURE-" + UUID.randomUUID() + "." + extension);
        boolean published = false;
        Object pendingKey = null;
        Throwable failure = null;
        try {
            pendingKey = requiredPathKey(pending);
            checkPathKey(directory, directoryKey);
            // The newly created pending file is empty. Do not truncate a replacement inode
            // before the opened descriptor has passed its identity checks.
            try (FileOutputStream output = new FileOutputStream(pending, true)) {
                if (identity != null) {
                    Object opened = identity.openedKey(output, pending);
                    if (opened == null || !opened.equals(pendingKey))
                        throw new IOException("Capture pending file changed while opening");
                    pendingKey = opened;
                }
                checkPathKey(directory, directoryKey);
                checkPathKey(pending, pendingKey);
                writer.write(output);
                output.flush();
                // Keep the descriptor open through validation and rename. These identity checks
                // reject controlled purge/substitution; they are not atomic with arbitrary host IO.
                checkPathKey(directory, directoryKey);
                checkPathKey(pending, pendingKey);
                if (pending.length() == 0)
                    throw new IOException("Encoder returned no image bytes");
                if (!pending.renameTo(completed))
                    throw new IOException("Could not publish capture file");
                checkPathKey(directory, directoryKey);
                checkPathKey(completed, pendingKey);
            }
            published = true;
            return completed;
        } catch (IOException | RuntimeException | Error error) {
            failure = error;
            throw error;
        } finally {
            if (!published) {
                for (File candidate : new File[] {pending, completed}) {
                    try { removeMatchingFile(candidate, pendingKey); }
                    catch (IOException | RuntimeException | Error cleanup) {
                        if (failure != null) failure.addSuppressed(cleanup);
                        else throw cleanup;
                    }
                }
            }
        }
    }

    private Object requiredPathKey(File file) throws IOException {
        if (identity == null) return null;
        Object key = identity.pathKey(file);
        if (key == null) throw new IOException("Capture file identity is unavailable");
        return key;
    }

    private void checkPathKey(File file, Object expected) throws IOException {
        if (identity != null && !expected.equals(identity.pathKey(file)))
            throw new IOException("Capture path changed while encoding: " + file.getName());
    }

    private void removeMatchingFile(File file, Object expected) throws IOException {
        if (!file.exists()) return;
        // Skip a path if its current identity differs from this publication's descriptor.
        if (identity != null && (expected == null || !expected.equals(identity.pathKey(file)))) return;
        if (!file.delete()) throw new IOException("Could not remove failed capture " + file.getName());
    }

    boolean release(String uri) throws IOException {
        synchronized (CaptureFiles.class) { return releaseLocked(uri); }
    }

    private boolean releaseLocked(String uri) throws IOException {
        File file;
        try {
            file = new File(URI.create(uri)).getAbsoluteFile();
        } catch (IllegalArgumentException error) {
            throw new IOException("URI is not a capture owned by this module", error);
        }
        if (!directory.getAbsoluteFile().equals(file.getParentFile()) ||
            !ownsName(file.getName()) || !file.getCanonicalFile().equals(file)) {
            throw new IOException("URI is not a capture owned by this module");
        }
        if (!file.exists())
            return false;
        if (!file.isFile() || !file.delete())
            throw new IOException("Could not remove capture " + file.getName());
        return true;
    }

    int clear() throws IOException {
        synchronized (CaptureFiles.class) { return clearLocked(); }
    }

    private int clearLocked() throws IOException {
        if (!directory.exists())
            return 0;
        if (!directory.getCanonicalFile().equals(directory.getAbsoluteFile()))
            throw new IOException("Capture cache is a link");
        File[] files = directory.listFiles();
        if (files == null)
            throw new IOException("Could not list capture cache");
        int removed = 0;
        IOException failure = null;
        for (File file : files) {
            boolean pending = file.getName().matches("CAPTURE-[-0-9]+\\.pending");
            if (!ownsName(file.getName()) && !pending)
                continue;
            try {
                if (pending) {
                    if (!file.isFile() || !file.getCanonicalFile().equals(file.getAbsoluteFile()) ||
                        !file.delete()) {
                        throw new IOException("Could not remove failed capture " + file.getName());
                    }
                    removed++;
                } else if (release(file.toURI().toString()))
                    removed++;
            } catch (IOException error) {
                if (failure == null)
                    failure = error;
            }
        }
        if (failure != null)
            throw new IOException("Cache cleanup failed after removing " + removed + " files",
                                  failure);
        return removed;
    }

    private static boolean ownsName(String name) {
        return name.matches(
            "CAPTURE-[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\\.(png|jpg)");
    }

    static int[] scaledSize(int width, int height, double scale) {
        double w = Math.max(1, Math.round(width * scale));
        double h = Math.max(1, Math.round(height * scale));
        if (!Double.isFinite(scale) || scale <= 0 || !Double.isFinite(w * h) ||
            w > Integer.MAX_VALUE || h > Integer.MAX_VALUE || w * h > 64000000) {
            throw new IllegalArgumentException(
                "Scaled capture exceeds 64 megapixels or scale is invalid");
        }
        return new int[] {(int)w, (int)h};
    }
}
