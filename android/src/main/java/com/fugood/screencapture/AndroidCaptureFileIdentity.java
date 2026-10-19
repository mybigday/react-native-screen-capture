package com.fugood.screencapture;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructStat;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

/** Android API 21+ identity binding; no Java NIO filesystem APIs or JNI dependency. */
final class AndroidCaptureFileIdentity implements CaptureFiles.IdentityChecker {
    @Override public Object pathKey(File file) throws IOException {
        try {
            return new Key(Os.lstat(file.getAbsolutePath()));
        } catch (ErrnoException error) {
            if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ENOTDIR) return null;
            throw new IOException("Could not inspect capture path identity", error);
        }
    }

    @Override public Object openedKey(FileOutputStream output, File path) throws IOException {
        try {
            return new Key(Os.fstat(output.getFD()));
        } catch (ErrnoException error) {
            throw new IOException("Could not inspect capture descriptor identity", error);
        }
    }

    private static final class Key {
        final long device, inode;
        Key(StructStat stat) { device = stat.st_dev; inode = stat.st_ino; }
        @Override public boolean equals(Object other) {
            if (!(other instanceof Key)) return false;
            Key key = (Key) other;
            return device == key.device && inode == key.inode;
        }
        @Override public int hashCode() {
            return 31 * (int) (device ^ (device >>> 32)) + (int) (inode ^ (inode >>> 32));
        }
    }
}
