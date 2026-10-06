package com.fugood.screencapture;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;

/** Real small filesystem operations and injected writer errors, never disk/memory exhaustion. */
public final class CaptureFilesTest {
    private static int assertions;
    static void check(boolean condition) { assertions++; if (!condition) throw new AssertionError(assertions); }
    static void rejects(Throwing action, String message) throws Exception {
        try { action.run(); throw new AssertionError("Expected failure"); }
        catch (IOException | IllegalArgumentException error) { check(error.getMessage().contains(message)); }
    }
    interface Throwing { void run() throws Exception; }
    public static void main(String[] args) throws Exception {
        File root = Files.createTempDirectory("rnsc-files-test-").toFile();
        CaptureFiles store = new CaptureFiles(root);
        File host = new File(root, "CAPTURE12345.png"); Files.writeString(host.toPath(), "host/legacy file");
        File image = store.publish("png", out -> out.write(new byte[] { 1, 2, 3 }));
        check(image.length() == 3);
        check(store.release(image.toURI().toString()));
        check(!store.release(image.toURI().toString()));
        rejects(() -> store.release(host.toURI().toString()), "not a capture");
        for (String error : new String[] { "ENOSPC injected", "EACCES injected", "encoder failed" }) {
            rejects(() -> store.publish("png", out -> { out.write(1); throw new IOException(error); }), error);
            check(new File(root, "react-native-screen-capture").list().length == 0);
        }
        rejects(() -> store.publish("png", out -> {}), "no image bytes");
        check(store.clear() == 0); check(host.exists());
        File outside = new File(root, "outside"); outside.mkdir();
        File folder = new File(root, "react-native-screen-capture"); check(folder.delete());
        Files.createSymbolicLink(folder.toPath(), outside.toPath());
        File victim = new File(outside, "CAPTURE-00000000-0000-0000-0000-000000000000.png");
        Files.writeString(victim.toPath(), "keep");
        rejects(() -> store.publish("png", out -> out.write(1)), "regular directory");
        rejects(store::clear, "link");
        rejects(() -> store.release(new File(folder, victim.getName()).toURI().toString()), "not a capture");
        check(victim.exists()); check(folder.delete());
        check(folder.mkdir());
        File pending = new File(folder, "CAPTURE-123456.pending"); Files.writeString(pending.toPath(), "failed residue");
        check(store.clear() == 1); check(!pending.exists());
        // Two stores share a process-wide file lock: cleanup cannot delete a file mid-write.
        CaptureFiles second = new CaptureFiles(root);
        CountDownLatch writerEntered = new CountDownLatch(1), unblock = new CountDownLatch(1);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        Thread writer = new Thread(() -> {
            try { store.publish("jpg", out -> {
                writerEntered.countDown();
                try { unblock.await(); } catch (InterruptedException error) { throw new IOException(error); }
                out.write(1);
            }); } catch (Throwable error) { failure.set(error); }
        });
        Thread cleanup = new Thread(() -> { try { check(second.clear() == 1); } catch (Throwable error) { failure.set(error); } });
        writer.start(); writerEntered.await(); cleanup.start(); unblock.countDown(); writer.join(); cleanup.join();
        if (failure.get() != null) throw new AssertionError(failure.get());
        check(folder.list().length == 0);
        check(CaptureFiles.scaledSize(8, 4, 0.001)[0] == 1);
        for (double scale : new double[] { 0, -1, Double.NaN, Double.POSITIVE_INFINITY, Double.MAX_VALUE, 100000 }) {
            rejects(() -> CaptureFiles.scaledSize(1080, 2340, scale), "invalid");
        }
        for (int i = 0; i < 100; i++) {
            File capture = store.publish("png", out -> out.write(1));
            check(store.release(capture.toURI().toString()));
        }
        check(folder.list().length == 0); check(host.exists());
        System.out.println("{\"assertions\":" + assertions + ",\"passed\":true}");
        // Only this test's own temporary directory.
        try (var paths = Files.walk(root.toPath())) {
            paths.sorted(java.util.Comparator.reverseOrder()).forEach(path -> {
                try { Files.delete(path); } catch (IOException error) { throw new RuntimeException(error); }
            });
        }
    }
}
