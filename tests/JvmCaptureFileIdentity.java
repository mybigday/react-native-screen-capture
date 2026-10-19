package com.fugood.screencapture;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.NoSuchFileException;
import java.nio.file.attribute.BasicFileAttributes;

/** Test-only path identity. The JVM opened-key boundary is a path snapshot, not real fstat. */
final class JvmCaptureFileIdentity implements CaptureFiles.IdentityChecker {
    int openedReads;
    @Override public Object pathKey(File file) throws IOException {
        try {
            return Files.readAttributes(file.toPath(), BasicFileAttributes.class,
                                        LinkOption.NOFOLLOW_LINKS).fileKey();
        } catch (NoSuchFileException absent) {
            return null;
        }
    }
    @Override public Object openedKey(FileOutputStream output, File path) throws IOException {
        if (!output.getFD().valid()) throw new IOException("Probe descriptor is closed");
        openedReads++;
        return pathKey(path);
    }
}
