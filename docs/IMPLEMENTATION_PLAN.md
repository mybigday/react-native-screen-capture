# Implementation Plan — capture rework + RN modernization

Branch: `feat/capture-rework-and-rn-modernization`
Tracking issue: [#2](https://github.com/mybigday/react-native-screen-capture/issues/2)

## 0. Decisions taken

| Question | Decision | Why |
| --- | --- | --- |
| MediaProjection backend (issue #2's original ask) | **Dropped** | Android 14+ forbids caching the consent `Intent`; consent cannot survive a process restart, so every cold start would show a system dialog. Plus mandatory foreground service + persistent notification + Android 15 QPR1 status-bar chip + auto-stop on lock. Too invasive for a screenshot utility. |
| `screenshotty` library | **Not used** | Last commit 2021-07. No Android 14 per-session-consent or FGS-type handling. Adopting it means rewriting it anyway. |
| Per-package adapter registry on iOS | **Rejected** | Requires upstream packages to cooperate. Not realistic. |
| iOS strategy | **Runtime introspection of AVFoundation objects** | Matching on `AVCaptureVideoPreviewLayer` / `AVPlayerLayer` / `AVPlayerViewController` covers whole classes of packages at once, with zero user setup. |
| Java package rename `com.lewin.capture` -> `com.fugood.screencapture` | **Done** | Reversed an earlier "cosmetic, defer it" call. The accessibility service is the one place the package name leaks into user code -- app authors paste the class name into their own manifest -- and that feature is new in 2.0.0, so nobody has it baked in yet. Renaming later would be a real breaking change; renaming now costs nothing. |
| Licence | **MIT**, two copyright holders | The repo had no LICENSE file at all, `package.json` said ISC and the podspec said MIT. Settled on MIT with `Copyright (c) 2018 LewinJun` alongside `Copyright (c) 2022 BRICKS INC.`, since one file is still upstream code verbatim. |
| Codegen spec object types | **`UnsafeObject`** | Declaring `capture`'s options as a codegen struct makes codegen emit `JS::NativeScreenCapture::NativeCaptureOptions &` on iOS, which forces Obj-C++ plus a separate old-arch implementation. `UnsafeObject` yields `NSDictionary` / `ReadableMap` and one implementation for both architectures. The public API in `src/index.ts` stays fully typed. |

Resulting capture modes:

- `view` — default, zero permissions, zero notifications. App's own windows only.
- `accessibility` — Android only, opt-in. Whole screen including other apps.

## 1. Why the current implementation cannot capture video

### Android
`PixelCopy.request(Window, ...)` reads back the **window's own** surface. A `SurfaceView`
lives on a *separate* surface composited by SurfaceFlinger and punches a transparent hole in
the window layer, so it never appears in that readback. `ScreenUtils.captureChildSurfaceView`
works around this by copying each `SurfaceView` separately and pasting it back, but:

- pastes with `getLocationInWindow` translation only — no scale / rotation / clip
- ignores z-order, so a `SurfaceView` that is partially covered gets painted **over** the
  views that cover it
- runs the copies **serially**, each with `latch.await(5, TimeUnit.SECONDS)`; N SurfaceViews
  is a worst case of N x 5s
- allocates a second full-screen `ARGB_8888` bitmap and blits the first into it
- `snapShotWithoutStatusBar` gates on `SDK_INT >= 24` but the `PixelCopy.request(Window, ...)`
  overload is **API 26** — `NoSuchMethodError` on API 24/25

### iOS
`drawViewHierarchyInRect:afterScreenUpdates:` (commit 81f5581) renders through Core Graphics.
`AVPlayerLayer`, `AVSampleBufferDisplayLayer` and `AVCaptureVideoPreviewLayer` are composited
by the GPU/render server and are **not** reachable from that path — they come out black on
device. They render fine in the Simulator, which is why this looks like it works.

## 2. The shared idea: placeholder compositing

Both platforms use the same trick, which removes all manual z-order and occlusion maths:

1. Grab the current frame of each media component out of its own framework.
2. Inject that frame **into the media component's own layer/view** as a temporary overlay.
3. Do **one** normal full-hierarchy capture.
4. Remove the temporary overlay.

Because the placeholder sits inside the media view, everything drawn on top of that view still
draws on top of the placeholder, and clipping / corner radius / transforms are applied by the
view system for free. Cost is O(1) full-screen renders regardless of how many media components
are on screen.

### Android form
```
for each SurfaceView:  PixelCopy.request(surfaceView, bmp)      // all in flight at once
                       surfaceView.getOverlay().add(BitmapDrawable(bmp))
single:                PixelCopy.request(window, ...)
cleanup:               surfaceView.getOverlay().clear()
```
The overlay drawable is painted by the View system into the window surface, covering the
transparent hole — so the single window readback picks it up in the right z-order.

### iOS form
```
for each media view:   frame = provider.copyCurrentFrame()
                       mediaView.layer.addSublayer(placeholder(contents: frame))
single:                drawViewHierarchyInRect(afterScreenUpdates: true)
cleanup:               placeholder.removeFromSuperlayer()
```

## 3. iOS frame providers (introspection table)

Walk the view tree; match on framework objects reached through **public** properties, never on
private layer classes (Apple can and does change those).

| Matched on | Frame source | Covers |
| --- | --- | --- |
| `AVCaptureVideoPreviewLayer.session` | `AVCaptureVideoDataOutput` | VisionCamera (confirmed: `HybridPreviewView.swift`), expo-camera, camera-kit |
| `AVPlayerLayer.player` | `AVPlayerItemVideoOutput.copyPixelBuffer(forItemTime:)` | anything driving an `AVPlayerLayer` directly |
| `AVPlayerViewController.player` | same as above | react-native-video (confirmed: `VideoComponentView.swift` uses `AVPlayerViewController`), expo-video, expo-av |
| `AVSampleBufferDisplayLayer` | swizzle `enqueue(_:)`, keep last buffer | webrtc / low-latency players — **phase 2** |

Ship a `__DEV__`-only `dumpHierarchy()` so adding support for a new package is "run the dump,
read the class names, add a rule" rather than guesswork.

### Zero steady-state cost
Attaching an `AVPlayerItemVideoOutput` makes the decoder emit an extra app-readable copy, so it
must not be permanent.

- lazy attach on first capture; wait 1–2 frames (16–33ms) for the first buffer
- keep attached while captures keep coming; detach after ~3s idle
- optional `warmUp()` / `coolDown()` for callers that know they are about to burst
- camera: retain exactly **one** `CVPixelBuffer`, with `alwaysDiscardsLateVideoFrames = true`,
  so we never starve VisionCamera's buffer pool
- iOS 16+ allows a second `AVCaptureVideoDataOutput` on a session; on iOS 15 wrap the existing
  output's delegate and forward

### Pixel path
`CVPixelBuffer` -> `CGImage` via a single cached Metal-backed `CIContext` (safe default).
`CVPixelBufferGetIOSurface` straight into `layer.contents` is zero-copy but undocumented —
implement behind a flag, measure, then decide.

### Geometry to carry over
- `videoGravity` -> `contentsGravity` (`resizeAspect` / `resizeAspectFill`)
- `AVCaptureConnection.isVideoMirrored` (front camera) — otherwise the snapshot is flipped
- `AVCaptureConnection.videoRotationAngle` (iOS 17+, replaces `videoOrientation`)

### Optimisation to measure
`afterScreenUpdates: true` forces a synchronous commit (~50–100ms full screen @3x). Try
`CATransaction.flush()` after inserting placeholders, then `afterScreenUpdates: false`.

## 4. Known-unfixable

| | Result | Note |
| --- | --- | --- |
| FairPlay DRM video (iOS) | black | decoded frames never leave the secure path |
| `FLAG_SECURE` / DRM surface (Android) | black or `ERROR_SOURCE_NO_DATA` | by design |
| Other apps / real system bars (`view` mode) | not captured | use `accessibility` mode |

Must be stated plainly in the README.

## 5. Android accessibility mode

- `takeScreenshot(displayId, executor, callback)` — API 30; `takeScreenshotOfWindow` — API 34
- service XML **must** carry `android:canTakeScreenshot="true"`, else
  `SecurityException: Services don't have the capability of taking the screenshot`
- rate limited — handle `ERROR_TAKE_SCREENSHOT_INTERVAL_TIME_SHORT` (~333ms in AOSP; do not
  hardcode a throttle, react to the error)
- result is a `HardwareBuffer` -> `Bitmap.wrapHardwareBuffer(buffer, colorSpace)`; `close()` it
- cannot be enabled programmatically — deep-link to `Settings.ACTION_ACCESSIBILITY_SETTINGS`
- **the `<service>` declaration must NOT live in the library manifest.** Manifest merger would
  push an accessibility service onto every consumer app and drag them all into Google Play's
  Accessibility API policy review — including people who only ever use `view` mode. The library
  ships the class plus a documented snippet; the app author opts in.

## 6. JS API

```ts
type CaptureMode = 'auto' | 'view' | 'accessibility'

capture(options?: CaptureOptions): Promise<CaptureResult>
setMode(mode: CaptureMode): void
getPermissionStatus(): Promise<PermissionStatus>
requestPermission(): Promise<PermissionStatus>
openAccessibilitySettings(): Promise<void>
addScreenshotListener(cb): Subscription
clearCache(): Promise<void>
warmUp(): Promise<void>
coolDown(): Promise<void>
```

`auto` resolves to `accessibility` when the service is enabled, otherwise `view`.
1.x names (`screenCapture`, `startListener`, `stopListener`) stay as deprecated aliases for one
major version.

## 7. RN modernization

| Area | From | To |
| --- | --- | --- |
| AGP | 3.1.4 | 8.x + `namespace` |
| compileSdk / minSdk | 29 / 16 | 36 / 24 |
| RN android dep | `com.facebook.react:react-native:+` | `com.facebook.react:react-android` |
| zxing | `com.google.zxing:core` (unused) | removed |
| iOS deployment target | 7.0 | 15.1 |
| podspec RN dep | `s.dependency "React"` | `install_modules_dependencies(s)` |
| Arch | old only | TurboModule + old-arch fallback |
| JS | `index.js` with stray Flow types | TypeScript + builder-bob |
| Types | none | codegen spec + shipped `.d.ts` |

Android screenshot **detection** should also move to `Activity#registerScreenCaptureCallback`
(API 34, `DETECT_SCREEN_CAPTURE`) instead of the current `ContentObserver` + filename keyword
match, which is unreliable under scoped storage. The callback gives no image — but this module
can take the screenshot itself, which closes the loop.

## 8. Order of work

1. Build infra / new-arch scaffolding (touches every file; do it first)
2. Android capture rework — overlay + parallel + API-level fix
3. Android accessibility mode
4. iOS introspection + placeholder compositing
5. README rewrite

## 9. What actually landed

All of sections 1-8 are implemented on branch `feat/capture-rework-and-rn-modernization`.

Verified locally:

- `tsc --noEmit` clean
- `bob build` clean (commonjs + module + typescript)
- codegen runs and produces `capture(ReadableMap, Promise)` on Android and
  `capture:(NSDictionary *)options resolve:reject:` on iOS -- both match the hand-written module
- **`example/android` builds a real debug APK**, through the actual React Native Gradle Plugin,
  alongside react-native-video and react-native-safe-area-context:
  - new architecture (RN 0.81 default): `BUILD SUCCESSFUL`. Codegen emitted
    `NativeScreenCaptureSpec.java` into `com.fugood.screencapture` plus the JNI/C++ artifacts, and the
    `newarch` source set compiled against it.
  - old architecture (`-PnewArchEnabled=false`): `BUILD SUCCESSFUL`. Verified with `javap` that
    `ScreenCaptureSpec` then extends `ReactContextBaseJavaModule` and that no codegen spec class
    is present -- so the source-set switch genuinely works rather than reusing the other AAR.
- `example` typechecks against the library's published `.d.ts`, which also proves the
  `package.json` `exports` map resolves correctly

### Not done -- follow-up work

- iOS code is **review-only here** -- there is no macOS in this environment, so none of it has
  been compiled or run. Everything in the checklist below is still open.
- `AVSampleBufferDisplayLayer` support (react-native-webrtc) is designed but not implemented.
- Java package rename `com.fugood.screencapture` -> `com.fugood.screencapture`.

## 10. Example app

`Example/` was replaced rather than upgraded. It was a leftover `ReactNavigationTVDemo`
scaffold: named after an unrelated demo, pinned to `react-native-tvos@0.64.2-0`, carrying
react-navigation 5 / reanimated 2.2 / screens 3.4 plus two patches that this library never used,
with iOS target folders still called `ReactNavigationTVDemo*`. Upgrading that in place would
have been migration work for code with no bearing on this package.

`example/` is a fresh RN 0.81 app (new architecture on by default) wired to the library through
`link:..` plus a `react-native.config.js` override, so autolinking picks the library up straight
from the repo root and Metro resolves it from TypeScript source.

It exercises the feature that motivated the whole change: a `react-native-video` player with
`useTextureView={false}`, which forces a `SurfaceView` on Android -- exactly the case a plain
window readback cannot see. Capture it and the frame should be in the result. Alongside that it
drives the mode selector, the accessibility permission flow, screenshot detection, `warmUp` /
`coolDown`, and `dumpHierarchy`.

Building it is also the strongest verification available in this environment: it compiles the
library through the real React Native Gradle Plugin with codegen, on the new architecture.

## 10b. Measured on device

Pixel 7 Pro, 1080x2340, end to end from the JS call to the resolved promise:

| | time |
| --- | --- |
| PNG full resolution, `view` | 513 / 451 / 471 ms |
| PNG full resolution, `accessibility` | 479 / 478 / 497 ms |
| JPEG q80 `scale: 0.5`, `view` | 63 / 50 / 69 ms |

Two things follow. The capture mode is not the lever -- the two modes land within noise of each
other once the hardware-to-software copy is off the main thread. And PNG encoding of a
full-resolution phone screen costs ~8x everything else put together.

`PixelCopy.request(Window, ...)` was also confirmed empirically **not** to include `SurfaceView`
content, by temporarily disabling the overlay path and re-capturing: the video region came back
at mean RGB (27.8, 31.8, 40.7) with 0.0% non-black -- exactly the app background colour, i.e. an
empty hole -- against (81.3, 96.0, 57.3) and 80.5% with the overlay in place. This matches the
AOSP source, where the `Window` overload resolves to `sourceForWindow()` (the ViewRootImpl
surface) while the `SurfaceView` overload resolves to `getHolder().getSurface()`: two separate
surfaces, combined only by SurfaceFlinger at display time.

## 11. CI

`.github/workflows/ci.yml` runs everything that was verified by hand while building this,
so it stays verified.

| Job | Runner | Guards |
| --- | --- | --- |
| `library` | ubuntu | `tsc --noEmit`, `bob build`, codegen runs |
| `package` | ubuntu | `npm pack` and assert the tarball has what consumers need and nothing else |
| `bundle` | ubuntu | `react-native bundle` for both platforms |
| `android` (new / old arch) | ubuntu | builds the example APK, then asserts with `javap` that the **right** spec source set compiled |
| `ios` (new / old arch) | macos-15 | `bundle exec pod install` + `xcodebuild` for the simulator |

Two of these earn their keep immediately:

- **`ios` is the only place the Objective-C is ever compiled.** None of it has been built on
  this branch; the macOS job is what will first tell us whether it is even syntactically sound.
- **`package` caught a real bug the moment it was written**: `ios/generated/` (local codegen
  output) was being published in the npm tarball, because `files` listed `"ios"` and the
  `!ios/build` negation did not cover it. Narrowed `files` to `ios/ScreenCapture`.

The Android job does not just check that Gradle succeeds. The `newarch` / `oldarch` source-set
swap is the kind of wiring that fails silently -- Gradle will happily build the wrong one -- so
the job asserts on the compiled `ScreenCaptureSpec` superclass and on the presence of the
codegen output.

The iOS job also runs a **tvOS syntax check**. The podspec claims tvOS support (it always has,
and the old example was a react-native-tvos app), but the example has no tvOS target, so
`xcodebuild` cannot cover it. `AVCaptureSession` and `AVCaptureVideoPreviewLayer` are
`API_UNAVAILABLE(tvos)`, so the camera provider would not have compiled there at all -- shipped
broken, invisibly, because CI only built the iOS simulator. The five `RNSC*.m` sources depend
only on UIKit/AVFoundation, so clang can parse them against the tvOS SDK directly, which is
enough to catch that class of mistake. The camera provider is now behind `#if !TARGET_OS_TV`;
video capture still works on tvOS through `AVPlayerLayer`.

Gaps that remain: no ESLint gate (the repo has no root ESLint config), and no real tvOS *build*
-- adding a tvOS target to the example would close that properly.

## 12. Verification

Android library compiles locally (SDK 33–36 + JDK 17 present). iOS is **review-only** in this
environment — no macOS. The following need a real device before release:

- [~] **iOS: verified as far as a simulator can take it** (Xcode 26.6, iPhone 17 Pro sim, iOS 26.5).
      Everything up to the final render is proven:
      - discovery matches: `m=1/86`, `react_native_video.RCTVideo layer=CALayer <- AVPlayerLayer`.
        Note react-native-video 6.19.2 uses `AVPlayerLayer`, not the `AVPlayerViewController`
        seen on its master branch -- both rules exist, and the AVPlayerLayer one fired.
      - the frame pipeline actually delivers: `hasFrame=YES`, `gravity=resizeAspect`
      - `capture()` completes end to end, 1206x2622 in 272ms, no crash, view tree intact after
      What a simulator **cannot** answer is the only thing left: whether `drawViewHierarchy`
      picks up the placeholder on a real device. In the simulator it captures AVFoundation layers
      natively, so the result looks identical either way. That needs the device.
- [x] **iOS on a real device (iPhone XR, iOS 18.7.9) -- and the result contradicts the premise
      this design was built on.** Captured twice back to back, once with the placeholder pass and
      once with it skipped behind a temporary debug flag, then pulled both PNGs off the device:

      | | video region | non-black |
      | --- | --- | --- |
      | with placeholder | mean RGB (66.0, 81.0, 55.3) | 67.0% |
      | placeholder skipped | mean RGB (66.3, 81.1, 55.5) | 67.4% |

      Identical. The provider was genuinely live at the time (`hasFrame=YES` on device), so the
      placeholder really was installed in the first capture -- and the video shows up without it
      just the same. **`drawViewHierarchyInRect:afterScreenUpdates:YES` captures AVPlayerLayer
      content natively on iOS 18.7.** For this case the placeholder machinery is redundant.

      Scope of that claim, before acting on it: it covers non-DRM video in an `AVPlayerLayer` on
      iOS 18.7 only. It says nothing about `AVCaptureVideoPreviewLayer`, which is where the
      black-frame reports are most consistent, nor about older iOS versions, nor about
      `AVSampleBufferDisplayLayer`.
- [ ] **iOS: VisionCamera (`AVCaptureVideoPreviewLayer`) -- untested, and now the deciding
      question.** If drawViewHierarchy also handles camera preview, the whole iOS provider stack
      is unnecessary complexity paying a real decoder/capture cost, and should be deleted. If it
      does not, the stack earns its place and this is simply a case where it was not needed.
- [ ] iOS: `afterScreenUpdates: false` + `CATransaction.flush()` — does it pick up the placeholder?
- [ ] iOS: IOSurface-direct `layer.contents` vs `CIContext` conversion timings
- [x] **Android: overlay drawable really does cover the SurfaceView hole in the window readback.**
      Confirmed on a Pixel 7 Pro (Android 17 / API 37), new architecture, release build, with a
      react-native-video player on a `SurfaceView`. In the resulting 1080x2340 capture the video
      region measured mean RGB (81, 96, 57) with 80.5% non-black pixels, against (28, 32, 41) and
      0% for a control patch of app background -- a 3x green-channel ratio. The frame is in the
      capture, not a black hole. `dumpHierarchy` also works on device (6ms), and the library's
      `DETECT_SCREEN_CAPTURE` permission merges into the host app correctly.
- [x] **Android: accessibility mode**, verified end to end on the Pixel 7 Pro (API 37) with the
      user's authorisation, and the device restored afterwards:
      - the service declaration merges from the example's manifest, and the platform grants it
        `capabilities=128` (`CAPABILITY_CAN_TAKE_SCREENSHOT`), so the
        `android:canTakeScreenshot="true"` flag in the XML is doing its job
      - `getPermissionStatus('accessibility')` reports `denied` while off and `granted` once the
        service binds
      - capturing with the service off rejects cleanly ("Accessibility service is not connected.
        Enable it in Settings > Accessibility.") instead of crashing
      - capturing with it on returns a full 1080x2340 image that **includes the real system
        status bar and navigation bar**: 6.0% bright pixels in the top strip against 0.3% for the
        same strip of a `view`-mode capture. That is the whole display, not just the app window.
- [ ] Android: accessibility mode capture on API 30 (the minimum for `takeScreenshot`)

Two platform behaviours worth knowing, both hit during that run and now in the README:

- Android blocks accessibility services for apps installed outside the Play Store, which covers
  anything `adb install`ed. The setting silently reverts until the restriction is cleared with
  `appops set <pkg> ACCESS_RESTRICTED_SETTINGS allow`. The first attempt here looked exactly like
  a bug in `getPermissionStatus` -- it was not; the service really had been switched off again.
- `am force-stop` on the host app makes the system disable the service, since it treats the
  process dying as the service failing.
