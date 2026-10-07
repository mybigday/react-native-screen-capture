# Regression checks

Run from the repository root with Node, Python 3 and JDK 17. JS/JVM probes use React/Android
boundary doubles. Native probes use real Foundation/CoreVideo with UIKit, AVFoundation and
React doubles. These checks do not establish device or live-sensor behavior; Android descriptor
identity is modeled by a JVM path snapshot.

```sh
mkdir -p tests/out
npm run typecheck
node tests/js-lifecycle.cjs
javac --release 17 -d tests/out/java android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/CaptureFilesTest.java
java -cp tests/out/java com.fugood.screencapture.CaptureFilesTest
python3 tests/extract-request-probe.py
javac --release 17 -d tests/out/request android/src/main/java/com/fugood/screencapture/CaptureFiles.java tests/out/RequestControlFlowTest.java
java -cp tests/out/request com.fugood.screencapture.RequestControlFlowTest
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
```

On macOS with Xcode:

```sh
bash tests/run-native.sh
bash tests/compile-native.sh
python3 tests/provider-lifecycle.py --native
python3 tests/camera-streams.py
```

The syntax check uses a minimal React shim. Generated probes and source manifests stay under
`tests/out`. The native file-replacement tests can also be linked directly against the store:

```sh
for probe in LeafDeletionProbe WriteFailureLeafProbe; do
  xcrun clang -fobjc-arc -fblocks -framework Foundation -Iios/ScreenCapture \
    "tests/$probe.m" ios/ScreenCapture/RNSCFileStore.m -o "tests/out/$probe"
  "tests/out/$probe"
done
```

## Geometry image checker

Requires Pillow and 14 unmodified 828×1792 PNGs named `001-library.png` through
`014-library.png`. Fixture: media host (80,160,400,240) points, cyan control (20,20,60,30)
inside the host, red/green background quadrants. Two captures each: normal, rotations 90/180,
rounded clip radius 60, opacity 0.4, anchor (0.35,0.65), triangle (0,0)-(400,0)-(0,240).
`--media-sublayer` applies styles to an internal media layer while host/control stay fixed.

```sh
python3 tests/check-media-geometry.py /path/to/backing-layer-images
python3 tests/check-media-geometry.py --media-sublayer /path/to/internal-layer-images
```
