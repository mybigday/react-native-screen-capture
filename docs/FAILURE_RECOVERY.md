# Capture failure recovery

This change addresses independent render, provider lifecycle, encoding and storage failure
paths. It does not establish a single cause for every black screenshot report.

- iOS window rendering uses a transparent intermediate surface so a transparent secondary
  window cannot replace earlier content with an opaque black background. Final composition
  remains opaque; `afterScreenUpdates:YES` is unchanged.
- Media providers identify the presentation as well as its player/session. Discovery is
  revalidated after the frame wait, and a changed presentation rejects for a caller retry.
  Camera previews share a session reader while keeping separate presentation targets.
- Captures reject overlap before allocating images. Encoding and cache operations share
  serial ordering across module instances; teardown cancels stale queued operations.
- Nil codecs, write errors, late Android callbacks and terminal frame-poll exceptions settle
  once and release capture admission. Placeholder and temporary image/buffer ownership is
  cleaned up on exceptional paths.
- Captures use module-owned cache files with atomic publication. `releaseCapture(uri)`
  supports independent consumers; cleanup rejects links and paths outside that cache.
  Disk-full and permission errors are preserved. A purged cache directory is retried once.
- Listener startup failures remain retryable, and pending start/stop transitions reconcile
  the current subscriber state. Android observer sessions discard stale callbacks.

`README.md` describes caller-visible limits and cache migration. Existing Android files in
the host cache root are retained because a filename prefix does not establish ownership.

## Validation and remaining limits

The checks in [tests/README.md](../tests/README.md) exercise production control flow and real
filesystem operations with safe injected failures. They cover five JS lifecycle groups,
133 Java filesystem assertions, 11 extracted Android request checks and 302 native
Foundation/control-flow/CoreVideo checks. TypeScript, library codegen, Android legacy/new
architecture compilation and 16 Apple SDK syntax checks also passed.

These checks use explicit framework/bridge stubs where documented. They are not full React
Native application or device tests. The native syntax check uses a minimal React shim.

A separate signed UIKit iOS-on-Mac fixture reproduced a transparent-secondary-window black
capture with the original 3.1 renderer. In a sustained comparison, the baseline produced
240 whole-black images and an opacity-only candidate produced none in 240 captures.
The same fixture exposed stale provider reuse after remount. This evidence predates the
combined changes here and does not establish a natural long-duration onset.

A subsequent signed physical-iPhone matrix ran 668 native-core captures across static,
AV, fast/slow remount and sustained scenarios. The original 3.1 provider lost the media
region in 10/12 fast-remount captures and 50/180 sustained captures after controlled
remounts; the combined core candidate had no missing media region in those captures.
Provider events and the raw image regions were checked together. Neither iPhone variant
produced whole-black images. Its window-transition cases had only one window, so they
do not validate multiple-window visibility transitions.

A separate physical-iPhone file-store fault test found that Foundation standardized an
app-container path differently before and after cache creation. Release/clear rejected
the store's own newly published files. Re-standardizing both parent directories at
ownership-check time also handles an already-deleted file while retaining directory/link
checks. The test injects errors into
small synthetic writes; it does not fill a disk or exercise the React Promise boundary.
All nine physical store checks passed after the correction (publish, release, missing-file
release, outside-path protection, injected disk-full, recovery write, two cleanup passes and
symlink protection). An invalid screen produced the expected error, followed by eight
successful native-core AV captures in the same process.

Still required: real camera delegate restoration, transformed media pixels, full React
bridge teardown, physical tvOS/VLC and real multiple-window/display transitions. Memory
fault injection and bounded capture runs do not prove the absence
of all memory/resource leaks.
