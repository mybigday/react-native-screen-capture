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
