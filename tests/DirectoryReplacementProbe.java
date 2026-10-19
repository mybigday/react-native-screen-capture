package com.fugood.screencapture;

import java.io.File;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;

/** Controlled regression; all files belong to this probe. No disk/memory exhaustion. */
public final class DirectoryReplacementProbe {
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("rnsc-directory-replacement-");
        try {
            JvmCaptureFileIdentity identity = new JvmCaptureFileIdentity();
            CaptureFiles store = new CaptureFiles(root.toFile(), identity);
            Path directory = root.resolve("react-native-screen-capture");
            Path backup = root.resolve("original-cache");
            String[] pendingName = new String[1];
            File published = null;
            IOException rejected = null;
            try { published = store.publish("png", output -> {
                output.write('A');
                output.flush();
                File[] pending = directory.toFile().listFiles((parent, name) -> name.endsWith(".pending"));
                if (pending == null || pending.length != 1) throw new java.io.IOException("Probe setup");
                pendingName[0] = pending[0].getName();
                // Model another host component replacing the cache path while the original FD
                // remains open. The replacement bytes are test-owned; no unrelated writer is used.
                Files.move(directory, backup);
                Files.createDirectory(directory);
                Files.write(directory.resolve(pendingName[0]), new byte[] { 'B' });
            }); } catch (IOException error) { rejected = error; }
            byte[] actual = published == null ? new byte[0] : Files.readAllBytes(published.toPath());
            byte[] original = Files.readAllBytes(backup.resolve(pendingName[0]));
            Path replacement = directory.resolve(pendingName[0]);
            boolean replacementSurvived = Files.exists(replacement) &&
                Arrays.equals(Files.readAllBytes(replacement), new byte[] { 'B' });
            boolean reproduced = Arrays.equals(actual, new byte[] { 'B' }) &&
                                 Arrays.equals(original, new byte[] { 'A' });
            System.out.println("{\"reproduced\":" + reproduced +
                ",\"published_bytes\":" + Arrays.toString(actual) +
                ",\"original_bytes\":" + Arrays.toString(original) +
                ",\"replacement_survived\":" + replacementSurvived +
                ",\"rejected\":" + (rejected != null) +
                ",\"opened_snapshot_reads\":" + identity.openedReads +
                ",\"scope\":\"controlled cache-path replacement; JVM opened-key is a path snapshot\"}");
            if (reproduced || rejected == null || !replacementSurvived ||
                !Arrays.equals(original, new byte[] { 'A' }))
                throw new AssertionError("Must fail closed and preserve replacement/original bytes");
        } finally {
            // Only this probe's own temporary directory.
            try (var paths = Files.walk(root)) {
                paths.sorted(Comparator.reverseOrder()).forEach(path -> {
                    try { Files.delete(path); }
                    catch (java.io.IOException error) { throw new RuntimeException(error); }
                });
            }
        }
    }
}
