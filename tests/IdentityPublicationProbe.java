package com.fugood.screencapture;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Comparator;

/** Small production-store regressions; opened-key is a JVM snapshot, not Android fstat. */
public final class IdentityPublicationProbe {
    static int assertions;
    static void check(boolean value) { assertions++; if (!value) throw new AssertionError(assertions); }
    static final class Identity implements CaptureFiles.IdentityChecker {
        final JvmCaptureFileIdentity reader = new JvmCaptureFileIdentity();
        FileOutputStream opened;
        boolean failOpened, replaceCompleted, replacementObservedOpen;
        Path originalCompleted;
        @Override public Object pathKey(File file) throws IOException {
            if (replaceCompleted && file.getName().endsWith(".png") && file.exists()) {
                replaceCompleted = false;
                replacementObservedOpen = opened.getFD().valid();
                originalCompleted = file.toPath().getParent().getParent().resolve("original-completed");
                Files.move(file.toPath(), originalCompleted);
                Files.write(file.toPath(), new byte[] { 'B' });
            }
            return reader.pathKey(file);
        }
        @Override public Object openedKey(FileOutputStream output, File file) throws IOException {
            opened = output;
            if (failOpened) throw new IOException("Injected descriptor identity failure");
            return reader.openedKey(output, file);
        }
        boolean closed() throws IOException { return !opened.getFD().valid(); }
    }
    public static void main(String[] args) throws Exception {
        Path root = Files.createTempDirectory("rnsc-publication-identity-");
        try {
            Identity identity = new Identity();
            CaptureFiles store = new CaptureFiles(root.toFile(), identity);
            File file = store.publish("png", out -> out.write('A'));
            check(Arrays.equals(Files.readAllBytes(file.toPath()), new byte[] { 'A' }));
            check(identity.closed()); check(store.release(file.toURI().toString()));
            File directory = root.resolve("react-native-screen-capture").toFile();
            for (int i = 0; i < 10; i++) {
                IOException injected = new IOException("Injected writer failure " + i);
                try { store.publish("png", out -> { out.write('A'); throw injected; });
                      throw new AssertionError("Expected writer failure"); }
                catch (IOException error) { check(error == injected); }
                check(identity.closed()); check(directory.list().length == 0);
            }
            identity.failOpened = true;
            try { store.publish("png", out -> { throw new AssertionError("Writer must not run"); });
                  throw new AssertionError("Expected descriptor failure"); }
            catch (IOException error) { check(error.getMessage().contains("descriptor identity")); }
            check(identity.closed()); check(directory.list().length == 0);
            identity.failOpened = false;

            // The directory stays put; only the pending pathname is replaced during the writer.
            Path originalPending = root.resolve("original-pending");
            Path[] pending = new Path[1];
            try { store.publish("png", out -> {
                out.write('A'); out.flush();
                File[] candidates = directory.listFiles((parent, name) -> name.endsWith(".pending"));
                if (candidates == null || candidates.length != 1) throw new IOException("Probe setup");
                pending[0] = candidates[0].toPath();
                Files.move(pending[0], originalPending);
                Files.write(pending[0], new byte[] { 'B' });
            }); throw new AssertionError("Expected pending substitution failure"); }
            catch (IOException error) { check(error.getMessage().contains("path changed")); }
            check(identity.closed());
            check(Arrays.equals(Files.readAllBytes(pending[0]), new byte[] { 'B' }));
            check(Arrays.equals(Files.readAllBytes(originalPending), new byte[] { 'A' }));
            Files.delete(pending[0]); Files.delete(originalPending);

            // Model replacement immediately after rename, while the original descriptor is open.
            identity.replaceCompleted = true;
            try { store.publish("png", out -> out.write('A'));
                  throw new AssertionError("Expected completed substitution failure"); }
            catch (IOException error) { check(error.getMessage().contains("path changed")); }
            File[] replacements = directory.listFiles();
            check(identity.replacementObservedOpen); check(identity.closed());
            check(replacements != null && replacements.length == 1);
            check(Arrays.equals(Files.readAllBytes(replacements[0].toPath()), new byte[] { 'B' }));
            check(Arrays.equals(Files.readAllBytes(identity.originalCompleted), new byte[] { 'A' }));
            Files.delete(replacements[0].toPath()); Files.delete(identity.originalCompleted);
            file = store.publish("jpg", out -> out.write('C'));
            check(store.release(file.toURI().toString())); check(directory.list().length == 0);
            System.out.println("{\"passed\":true,\"assertions\":" + assertions +
                ",\"scope\":\"production CaptureFiles; JVM opened-key snapshot; no Android fstat execution\"}");
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
