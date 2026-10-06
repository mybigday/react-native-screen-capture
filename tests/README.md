# Failure recovery checks

These checks use the production source and small test-owned files. They inject failures instead
of exhausting disk or memory, and require no device, pairing, certificates, or security changes.

```sh
npm run typecheck
node tests/js-lifecycle.cjs
javac --release 17 -d tests/out/java android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/CaptureFilesTest.java
java -cp tests/out/java com.fugood.screencapture.CaptureFilesTest
python3 tests/extract-request-probe.py
javac --release 17 -d tests/out/request android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/out/RequestControlFlowTest.java
java -cp tests/out/request com.fugood.screencapture.RequestControlFlowTest
bash tests/run-native.sh # macOS/Xcode only
bash tests/compile-native.sh # iOS/tvOS SDK syntax, minimal React shim
```

Run `mkdir -p tests/out` before the Java commands on a fresh checkout.

- JS executes transpiled `src/index.ts` with a mocked native module/emitter and tests start/stop
  ordering, transient startup failure, foreground recovery, double unsubscribe and scale rejection.
- Java `CaptureFilesTest` uses the real filesystem, including links, throwing writers, empty
  encodes, concurrent stores, legacy-root preservation and 100 create/release cycles.
- The Android request probe extracts the byte-exact production `ScreenshotRequest` class into
  deterministic API/clock stubs. It tests timeout, late success, cancelled retries, disconnection,
  binder exceptions and copy errors. Its SHA manifest lives in `tests/out`.
- The native probe extracts the byte-exact production encode/serial/wait methods and uses the
  real Foundation file store. UIKit codecs and React callbacks are stubs. It tests nil codecs,
  preserved disk-full/permission NSError, cache-directory purge, throwing operations/callbacks,
  post-write cancellation/rollback failure, links, a parent alias created after store initialization,
  listing/deletion failure, repeated cleanup,
  and an exception at the terminal wait poll followed by successful queue progress.
  Real CoreVideo buffers also verify that a throwing converter releases each provider's
  temporary buffer retain before detach.

These are control-flow and filesystem tests. They do not prove React bridge teardown, camera
delegate behavior, transformed video pixels, or iPhone/tvOS media capture. Those require a signed
fixture/device run. The separate native-core hardware results and remaining limits are described
in [Failure recovery](../docs/FAILURE_RECOVERY.md); running these probes does not reproduce those
hardware checks.

## Physical media geometry readback

`check-media-geometry.py` requires Pillow and the 14 raw PNG files from the controlled
physical XR fixture (828×1792 pixels, two captures per style). The fixture has a
400×240-point media host at (80,160), a cyan control at local (20,20,60,30), and pure
red/green background quadrants. Styles are normal, 90/180-degree rotation, a 60-point
rounded clip, 0.4 opacity, anchor (0.35,0.65), and a triangle joining (0,0), (400,0),
(0,240). A second variant applies those styles to an internal media layer while its
host/control remain fixed. Use the raw capture output, with no resizing or color edits.

```sh
python3 tests/check-media-geometry.py /path/to/backing-layer-images
python3 tests/check-media-geometry.py --media-sublayer /path/to/internal-layer-images
```

Expected fixture colors independently check clipping, alpha and visible control order;
all 14 images are checked for whole-black output. The original 3.1 fixture fails these
checks, and the corrected fixture passes both structures. This script verifies supplied
hardware output; it does not launch an app, reproduce a live camera session, or replace
the broader device tests described in the linked validation notes.


## Follow-up resource and continuation probes

The following probes extract production methods into deterministic framework doubles. Their
source manifests and generated harnesses stay under `tests/out`; they do not allocate large
bitmaps, fill a disk, use live cameras or prove Android runtime behavior.

```sh
python3 tests/extract-encoder-probe.py
javac --release 17 -d tests/out tests/out/EncoderSubmissionTest.java
java -cp tests/out com.fugood.screencapture.EncoderSubmissionTest
python3 tests/extract-display-probe.py
javac --release 17 -d tests/out/display android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/out/DisplayContinuationTest.java
java -cp tests/out/display com.fugood.screencapture.DisplayContinuationTest
python3 tests/extract-observer-cursor-probe.py
javac --release 17 -d tests/out/cursor tests/out/ObserverCursorTest.java
java -cp tests/out/cursor com.fugood.screencapture.ObserverCursorTest
python3 tests/extract-pixelcopy-probe.py
javac --release 17 -d tests/out/pixelcopy android/src/main/java/com/fugood/screencapture/PixelCopyBudget.java tests/out/PixelCopyBudgetTest.java
java -cp tests/out/pixelcopy com.fugood.screencapture.PixelCopyBudgetTest
javac --release 17 -d tests/out/identity android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/JvmCaptureFileIdentity.java tests/IdentityPublicationProbe.java tests/DirectoryReplacementProbe.java tests/PreOpenReplacementProbe.java
java -cp tests/out/identity com.fugood.screencapture.IdentityPublicationProbe
java -cp tests/out/identity com.fugood.screencapture.DirectoryReplacementProbe
java -cp tests/out/identity com.fugood.screencapture.PreOpenReplacementProbe
python3 tests/check-ios-storage-invariants.py --output tests/out/storage
python3 tests/provider-lifecycle.py
python3 tests/provider-lifecycle.py --native # macOS; Foundation/CoreVideo with AV doubles
python3 tests/camera-streams.py # macOS; real CoreVideo samples with AV doubles
```

The encoder probe covers worker creation failure before/after enqueue, cancellation ownership,
settlement and future admission (31 checks). Display continuation covers collected bitmap cleanup
and transfer of ownership (20). Cursor cleanup covers `isClosed`/`close` exceptions (eight).
PixelCopy/overlay checks cover reservations, missing/late/duplicate callbacks and throwing overlay
operations (178). Timeout leases deliberately survive until native completion.

Publication-identity checks use small real files and controlled replacements (48). The JVM opened
identity is a path snapshot; it does not exercise Android's real descriptor `fstat` implementation.
`DirectoryReplacementProbe` separately checks replacing the entire cache directory during writing.
`PreOpenReplacementProbe` checks substitution just before open, ensuring replacement bytes
are preserved without running the writer and the rejected descriptor closes. The iOS storage probe has eight arithmetic/POSIX behavioral checks and three source integration
checks. `LeafDeletionProbe.m` and `WriteFailureLeafProbe.m` can be linked with a selected real
`RNSCFileStore.m` on macOS to compare recursive-deletion baseline and leaf-unlink correction.

The native failure probe now also covers request-local autorelease lifetime across success,
write failure and throwing settlement callbacks, and independent primary-window selection (321
checks total). The portable provider model has 19 checks; native extraction has 20. Camera stream
selection/publication has 40 native checks, including front/back identity, ambiguous connection
refusal, delegate/queue restoration and recovery after a preview obtains a connection. These tests
use modeled AV configuration, not live sensor sessions or full React Native bridge behavior.
