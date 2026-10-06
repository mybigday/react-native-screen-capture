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
  post-write cancellation/rollback failure, links, listing/deletion failure, repeated cleanup,
  and an exception at the terminal wait poll followed by successful queue progress.
  Real CoreVideo buffers also verify that a throwing converter releases each provider's
  temporary buffer retain before detach.

These are control-flow and filesystem tests. They do not prove React bridge teardown, camera
delegate behavior, transformed video pixels, or iPhone/tvOS media capture. Those require a signed
fixture/device run. Existing Mac black-frame A/B evidence is kept outside this checkout under
the task's `diagnostics-19156/`; it predates the combined recovery changes.
