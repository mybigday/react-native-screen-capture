# Working on this repo

Notes for anyone — human or agent — changing this package. The README is for people *using* it;
this is the stuff you need to not waste a day. `docs/IMPLEMENTATION_PLAN.md` is the historical
record of how the current design was arrived at.

## The one thing to understand first

Video and camera layers are composited **out of the app's process**. They are not in the app's
render tree, so neither `PixelCopy.request(Window, …)` on Android nor
`drawViewHierarchyInRect:` on iOS can see them. This library works by pulling the current frame
out of the framework that owns it and injecting it into that component's own layer/view, then
doing a single normal capture:

- **Android** — `PixelCopy` each `SurfaceView`, install the result as a `ViewOverlay` on that
  same view, then one window readback.
- **iOS** — find the `AVPlayer` / `AVCaptureSession` by introspection, pull a frame, insert a
  placeholder `CALayer` above the media layer, then one `drawViewHierarchy` pass.

Both put the frame back where the view system will draw it, so z-order, clipping and transforms
come out right without computing occlusion, and the cost stays at one full-screen render.

## Traps

### Simulators lie about exactly the thing this library fixes

The iOS and tvOS simulators composite `AVPlayerLayer` and `AVCaptureVideoPreviewLayer` into a
`drawViewHierarchy` snapshot natively. Devices do not. Measured, video region, same build:

| | with our compositing | with it skipped |
| --- | --- | --- |
| iPhone XR / iOS 18.7 | 94.1% non-black, 102046 colours | (0,0,0), **1 colour** |
| iOS / tvOS simulator | full picture | full picture |

So a green simulator run proves nothing here. Anything about whether capture works has to be
measured on hardware.

Apple's [QA1817](https://developer.apple.com/library/archive/qa/qa1817/_index.html) is usually
what convinces people otherwise:

> "…enables you to capture the contents of the receiver view and its subviews to an image
> regardless of the drawing techniques (for example UIKit, Quartz, OpenGL ES, SpriteKit, etc)…"

Every technique in that list is drawing the app's own process performs. AVFoundation layers are
not a drawing technique at all, which is why they are absent. The sentence is true and still
misleading.

### `capture()` drops unknown option keys

`src/index.ts` rebuilds the options object from known keys before calling native. A debug flag
added to a `capture()` call therefore never reaches the native side. This silently turned an
A/B test into a comparison of two identical runs and produced a confidently wrong conclusion
that survived several rounds. If you need to pass something experimental, call the native module
directly:

```ts
const Native: any = TurboModuleRegistry.getEnforcing('ScreenCapture')
await Native.capture({ mode: 'view', extension: 'png', quality: 100, scale: 1,
                       excludeStatusBar: false, includeBase64: false, __yourFlag: true })
```

**Always sanity-check that an A/B actually differs in the way you intended before believing it.**

### Bundling successfully is not the same as running

`react-native bundle` succeeding says nothing about whether the app boots. A Metro resolver
change once shipped that bundled fine and crashed every app on launch with
`[runtime not ready] TypeError: … is not a function`. Specifically: do **not** add
`unstable_conditionNames: ['source', …]` to `example/metro.config.js` — it is global and changes
resolution for every package. The Metro warning it silences is harmless.

### Android

- Anything reading `Window`/`View`/insets belongs on the UI thread. `@ReactMethod`s do not run
  there — `WindowCapture.capture()` opens with `UI.post()` for exactly this reason. Measuring
  insets from a module method reads `ViewRootImpl` state off-thread and can tear or throw.
- `accessibility` mode captures the *display*, so this app's window insets are the wrong measure
  for it: they are 0 when the app is immersive or in the bottom split-screen pane, and the app is
  usually not even foreground. Use the platform's nominal `status_bar_height` there, and the real
  inset only for `view` mode, which really is cropping its own window.
- `PixelCopy.request(SurfaceView, Bitmap, listener, Handler)` is available from **API 24**, not
  26. Only the `Rect` and `Window` overloads are 26 — check `api-versions.xml` in the SDK before
  believing an availability claim:
  `platforms/android-<n>/data/api-versions.xml`, where a method with no `since` inherits the
  class's. This has already been reported once as a bug that was not one.
- `am force-stop` on an app hosting an accessibility service makes the system switch that
  service off. Restart the app instead when testing accessibility mode.
- Accessibility services are blocked for apps installed outside the Play Store, which includes
  anything `adb install`ed; the setting silently reverts. Clear it once with
  `adb shell appops set <pkg> ACCESS_RESTRICTED_SETTINGS allow`.
- Autolinking caches the resolved package list. After renaming the Java package, delete
  `example/android/app/build/generated/autolinking` or you get `package … does not exist`.
- Debug APKs load JS from Metro; release APKs embed it. Use release builds for unattended device
  testing so there is no Metro dependency.

### iOS build environment

- **React Native 0.81 pins fmt 11.0.2, which does not compile under Xcode 26** —
  `call to consteval function … is not a constant expression` out of `fmt/format-inl.h`. Upstream
  problem, hits any RN 0.81 project. Either build with Xcode 16 or force
  `FMT_USE_CONSTEVAL=0` for the fmt pod.
- Physical-device debug builds embed a JS bundle **and** prefer Metro when it is reachable, so
  editing JS may or may not need a rebuild depending on whether Metro is up.
- Run `pod install` with a consistent architecture setting. Mixing runs with and without
  `RCT_NEW_ARCH_ENABLED=1` leaves Pods in a state where the app uses legacy prop setters against
  a Fabric view and crashes with `unrecognized selector`.
- `xcodebuild` reuses `-derivedDataPath` aggressively. If a rebuild seems not to have happened,
  check the binary's timestamp before believing the log.

### codesign over SSH

macOS ties keychain access to the security session, and an SSH login gets its own, so `codesign`
fails with `errSecInternalComponent` no matter what you unlock. Starting `tmux` from the SSH
session does not help — it inherits the same session. What works: have someone start a tmux
server from a GUI Terminal once (`tmux new -d -s build`), then drive builds with
`tmux send-keys -t build …`, which run in the GUI session.

Wait for the pane to be idle before sending — keys sent while a build is running go to that
process's stdin, not the shell, and you will spend a while reading stale logs. Use a unique log
filename per run for the same reason.

## Verifying a capture change on hardware

The only trustworthy check is an A/B: capture once normally, once with the compositing skipped
behind a temporary debug flag, then compare the media region. A region that was never composited
in comes back as a *single uniform colour* — that, not "it looks dark", is the signal. Distinct
colour count is a better discriminator than mean brightness, which is why the tables above quote
it.

Pull the PNGs off the device rather than reading a preview:

```sh
# iOS
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
  --domain-identifier <bundle-id> \
  --source Library/Caches/react-native-screen-capture/<file>.png --destination ./out.png
```

`dumpHierarchy()` tells you whether a component was matched *and* whether its frame pipeline is
delivering (`hasFrame`). A matched component with `hasFrame=no` means the placeholder is a no-op,
which looks identical to "capture works natively" if you are not careful.

## What is still unverified

Real Apple TV hardware. tvOS is compile- and runtime-checked (a native harness against the tvOS
SDK on a simulator: discovery works, `hasFrame=YES`), but the simulator captures natively, so
whether the placeholder pass is *needed* there is unknown.
