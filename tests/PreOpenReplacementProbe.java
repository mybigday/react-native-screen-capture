package com.fugood.screencapture;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;

/** Controlled replacement just before open; every file belongs to this probe. */
public final class PreOpenReplacementProbe {
    static final class Identity implements CaptureFiles.IdentityChecker {
        final JvmCaptureFileIdentity reader = new JvmCaptureFileIdentity();
        final Path root, directory;
        File pending;
        FileOutputStream opened;
        boolean swapped;
        Identity(Path root) { this.root = root; directory = root.resolve("react-native-screen-capture"); }
        @Override public Object pathKey(File file) throws IOException {
            if (pending == null && file.getName().endsWith(".pending")) pending = file;
            if (pending != null && !swapped && file.toPath().equals(directory)) {
                swapped = true;
                Files.move(pending.toPath(), root.resolve("original-pending"));
                Files.write(pending.toPath(), new byte[] { 'B' });
            }
            return reader.pathKey(file);
        }
        @Override public Object openedKey(FileOutputStream output, File path) throws IOException {
            opened = output;
            return reader.openedKey(output, path);
        }
    }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("rnsc-preopen-replacement-");
        try {
            Identity identity = new Identity(root);
            CaptureFiles store = new CaptureFiles(root.toFile(), identity);
            boolean[] writerRan = { false };
            IOException rejected = null;
            try { store.publish("png", output -> { writerRan[0] = true; output.write('A'); }); }
            catch (IOException error) { rejected = error; }
            byte[] replacement = Files.readAllBytes(identity.pending.toPath());
            boolean closed = identity.opened != null && !identity.opened.getFD().valid();
            boolean passed = identity.swapped && rejected != null && !writerRan[0] && closed &&
                             Arrays.equals(replacement, new byte[] { 'B' });
            System.out.println("{\"passed\":" + passed + ",\"rejected\":" + (rejected != null) +
                ",\"writer_ran\":" + writerRan[0] + ",\"descriptor_closed\":" + closed +
                ",\"replacement_bytes\":" + Arrays.toString(replacement) +
                ",\"scope\":\"production store; controlled pre-open replacement; JVM key snapshot\"}");
            if (!passed) throw new AssertionError("Pre-validation open must preserve replacement B bytes");
        } finally {
            try (var paths = Files.walk(root)) {
                paths.sorted(Comparator.reverseOrder()).forEach(path -> {
                    try { Files.delete(path); }
                    catch (IOException error) { throw new RuntimeException(error); }
                });
            }
        }
    }
}
