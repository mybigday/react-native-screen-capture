# @fugood/react-native-screen-capture

[![CI](https://github.com/mybigday/react-native-screen-capture/actions/workflows/ci.yml/badge.svg)](https://github.com/mybigday/react-native-screen-capture/actions/workflows/ci.yml)

Programmatic screenshots for React Native — including the parts that normally come out black.

Video players and camera previews are composited by the GPU, not by the drawing APIs a normal
screenshot goes through. Capture them the usual way and you get a black rectangle where the
video should be. This module pulls the current frame out of the framework that owns it and
composites it back in, so what you get is what was on screen.

No root. No `MediaProjection` consent dialog. No foreground service.

- [Requirements](#requirements)
- [Install](#install)
- [Quick start](#quick-start)
- [API](#api)
- [Capture modes](#capture-modes)
- [What is and is not captured](#what-is-and-is-not-captured)
- [Supported media components](#supported-media-components)
- [Android: accessibility mode](#android-accessibility-mode)
- [Screenshot detection](#screenshot-detection)
- [Performance](#performance)
- [Migrating from 1.x](#migrating-from-1x)

## Requirements

| | |
| --- | --- |
| React Native | 0.76+ (old and new architecture) |
| Android | API 24+ (`accessibility` mode needs API 30+) |
| iOS | 15.1+ |
| tvOS | 15.1+ (video only -- tvOS has no camera APIs) |

## Install

```sh
npm install @fugood/react-native-screen-capture
cd ios && pod install
```

Autolinking handles the rest. Nothing to register manually.

## Quick start

```js
import ScreenCapture from '@fugood/react-native-screen-capture'

const shot = await ScreenCapture.capture()
// { uri: 'file:///.../CAPTURE-....png', width: 1170, height: 2532 }

<Image source={{ uri: shot.uri }} style={{ width: 100, height: 200 }} />
```

## API

### `capture(options?): Promise<CaptureResult>`

```ts
type CaptureOptions = {
  mode?: 'auto' | 'view' | 'accessibility'  // default 'auto'
  excludeStatusBar?: boolean                // default false
  extension?: 'png' | 'jpg' | 'jpeg'        // default 'png'
  quality?: number                          // 1-100, JPEG only, default 100
  scale?: number                            // default 1 (native size)
  includeBase64?: boolean                   // default false
}

type CaptureResult = {
  uri: string       // file:// URI in the app's cache directory
  base64?: string   // only when includeBase64 is true
  width: number     // pixels
  height: number
}
```

`includeBase64` costs a second full encode pass. Leave it off unless you need it — the file is
already written and `uri` works directly in `<Image>`.

Files land in the app's cache directory and are never cleaned up automatically. Call
`clearCache()` when it suits you.

### `setMode(mode)` / `getMode()`

Sets the default mode used by `capture()` when called without one.

### `getPermissionStatus(mode?)` / `requestPermission(mode?)`

Resolve to `'granted'`, `'denied'` or `'unavailable'`. Only meaningful for `accessibility`
mode; `view` mode is always `'granted'`.

`requestPermission('accessibility')` opens system settings and resolves with the status *before*
the user acted on it — the OS gives no callback. Re-check with `getPermissionStatus()` when your
app comes back to the foreground.

### `openAccessibilitySettings(): Promise<boolean>`

Android only. Deep-links to Settings → Accessibility. Resolves `false` on iOS.

### `isModeAvailable(mode): Promise<boolean>`

Whether the OS version supports the mode at all, regardless of permission.

### `warmUp()` / `coolDown()`

iOS only; no-ops elsewhere. See [Performance](#performance).

### `clearCache(): Promise<number>`

Deletes every file this module has written. Resolves with the count.

### `addScreenshotListener(cb): Subscription`

See [Screenshot detection](#screenshot-detection).

### `dumpHierarchy(): Promise<string>`

Development helper. Dumps the native view/layer tree with a note on every media component it
recognises. Use it when something is not being captured — see
[Supported media components](#supported-media-components).

## Capture modes

| Mode | Platform | Captures | Cost to the user |
| --- | --- | --- | --- |
| `view` (default) | both | this app's own windows | nothing |
| `accessibility` | Android 11+ | the whole display, other apps, real system bars | must enable a service in Settings, once |
| `auto` | both | `accessibility` if it is already enabled, otherwise `view` | nothing |

`MediaProjection` is deliberately **not** offered. Since Android 14 the consent `Intent` cannot
be cached or reused, so consent cannot survive a process restart — every cold start would show a
system dialog. It also requires a foreground service with a persistent notification, shows a
status-bar chip from Android 15 QPR1, and stops itself when the device locks. That is the wrong
shape for a screenshot utility. See [issue #2](https://github.com/mybigday/react-native-screen-capture/issues/2).

## What is and is not captured

| | `view` | `accessibility` |
| --- | --- | --- |
| App UI | yes | yes |
| Video / camera components | yes, see below | yes |
| `TextureView` (Android) | yes | yes |
| `SurfaceView` (Android) | yes | yes |
| Dialogs, `<Modal>`, other windows | iOS yes / **Android no** | yes |
| Real system bars | no | yes |
| Other apps | no | yes |
| DRM content | **no — black** | **no — black** |
| `FLAG_SECURE` windows (Android) | **no — black** | **no — black** |

Two limits are not fixable from an app and never will be:

- **FairPlay / Widevine L1 video comes out black.** Decoded frames never leave the hardware
  secure path, so no app-accessible API can read them. Apple and Google enforce this
  deliberately; the system screen recorders behave the same way.
- **`FLAG_SECURE` surfaces come out black on Android**, by design.

On Android, `view` mode captures the activity window only. Dialogs and React Native `<Modal>`
render into separate windows, and there is no public API to enumerate them — reaching them would
mean non-SDK reflection, which we do not do. Use `accessibility` mode if you need them.

The iOS status bar is drawn by a separate system process and is not in the app's windows, so it
is never captured. `excludeStatusBar: true` crops that area off.

## Supported media components

iOS discovery is pure runtime introspection: we look for AVFoundation objects reached through
**public** properties, never for package names or private classes. That means one rule covers a
whole class of packages, and nothing is required from those packages or from you.

| Found via | Frame source | Covers |
| --- | --- | --- |
| `AVCaptureVideoPreviewLayer.session` | `AVCaptureVideoDataOutput` | react-native-vision-camera, expo-camera, react-native-camera-kit |
| `AVPlayerLayer.player` | `AVPlayerItemVideoOutput` | anything driving an `AVPlayerLayer` |
| `AVPlayerViewController.player` | `AVPlayerItemVideoOutput` | react-native-video, expo-video, expo-av |

`AVSampleBufferDisplayLayer` (react-native-webrtc and some low-latency players) is **not** covered
yet.

Android needs no such table: `PixelCopy` works on any `SurfaceView` regardless of what renders
into it, and `TextureView` draws through the view hierarchy already.

### When something is not captured

```js
console.log(await ScreenCapture.dumpHierarchy())
```

The dump flags every media layer it recognises and marks the ones it does not. If your component
shows up unrecognised, open an issue with the dump — adding a rule is usually a small change.

## Android: accessibility mode

This mode is **opt-in and unlisted by default**. The service is not declared in this library's
manifest on purpose: manifest merging would push an accessibility service into every app that
depends on this package and drag all of them into Google Play's Accessibility API policy review,
including apps that only ever use `view` mode.

> **Before you ship this.** Google Play requires apps using the Accessibility API to serve users
> with disabilities, and to make a prominent disclosure of what the service does. Using it purely
> to take screenshots can get an app removed. It is a good fit for enterprise, kiosk and
> sideloaded builds, and a risky one for consumer apps on Play.

### 1. Declare the service in **your app's** `AndroidManifest.xml`

```xml
<service
    android:name="com.fugood.screencapture.ScreenCaptureAccessibilityService"
    android:exported="false"
    android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
  <intent-filter>
    <action android:name="android.accessibilityservice.AccessibilityService" />
  </intent-filter>
  <meta-data
      android:name="android.accessibilityservice"
      android:resource="@xml/screen_capture_accessibility_service" />
</service>
```

`@xml/screen_capture_accessibility_service` ships with this package. Copy it into your own
`res/xml/` if you want a different description string shown in Settings — the important part is
`android:canTakeScreenshot="true"`, without which the platform rejects every capture.

### 2. Send the user to Settings

```js
if (await ScreenCapture.getPermissionStatus('accessibility') !== 'granted') {
  await ScreenCapture.openAccessibilitySettings()
}
```

They have to enable it themselves under Settings → Accessibility → Downloaded apps. There is no
programmatic way to switch it on, and no callback when they do — re-check on app resume.

> **You will hit this during development.** Android blocks accessibility services for apps
> installed from outside the Play Store, which includes anything you `adb install` or run from
> Android Studio. The toggle either does nothing or silently reverts. Clear the restriction
> first: **Settings → Apps → your app → ⋮ → Allow restricted settings**, or from a shell:
>
> ```sh
> adb shell appops set <your.package> ACCESS_RESTRICTED_SETTINGS allow
> ```
>
> Also note that `adb shell am force-stop` on your app makes the system switch the service
> back off, since it treats the host process dying as the service failing.

### 3. Capture

```js
const shot = await ScreenCapture.capture({ mode: 'accessibility' })
```

The platform rate-limits these to roughly three per second. This module backs off and retries
once automatically; beyond that you will get an error.

## Screenshot detection

```js
const sub = ScreenCapture.addScreenshotListener(({ uri }) => {
  console.log('the user took a screenshot', uri)
})
sub.remove()
```

The event fires when *the user* takes a screenshot, not when you call `capture()`.

`uri` is almost always **undefined**: neither platform hands the user's screenshot file to the
app. If you need the image, take your own with `capture()` when the event arrives.

- **iOS** uses `UIApplicationUserDidTakeScreenshotNotification`.
- **Android 14+** uses `Activity.registerScreenCaptureCallback`. Add
  `<uses-permission android:name="android.permission.DETECT_SCREEN_CAPTURE" />` — this package
  already declares it, so autolinking covers you.
- **Android 13 and below** falls back to watching MediaStore for a new file whose name looks like
  a screenshot. This is unreliable under scoped storage and needs `READ_MEDIA_IMAGES` (or
  `READ_EXTERNAL_STORAGE`), which **your app** must declare and request. Without it, the fallback
  simply never fires.

## Performance

Nothing is attached while you are not capturing. An idle app pays exactly zero.

**iOS.** Pulling frames requires hooking into AVFoundation, which is not free — an
`AVPlayerItemVideoOutput` makes the decoder emit an extra app-readable copy. So providers attach
on the first `capture()` and detach again after ~3 idle seconds. The consequence is that the
*first* capture after an idle period waits one or two frames (16–33ms) for the pipeline to
produce something. If you are about to capture in a burst, call `warmUp()` first and `coolDown()`
when you are done.

Compositing is O(1) full-screen renders regardless of how many video or camera components are on
screen. Each frame is injected into its own component's layer, and then the whole hierarchy is
rendered **once**. The naive alternative — slicing the hierarchy into layers and rendering each
separately — costs a full render per component. The full-screen render itself is the expensive
part (roughly 30–100ms at @3x) and it has to happen on the main thread, so expect a dropped
frame.

Camera capture borrows the existing `AVCaptureVideoDataOutput` delegate rather than adding a
second output, and forwards every callback. Reconfiguring a live session causes a visible glitch
and can fail outright on some presets; borrowing disturbs nothing. Exactly one pixel buffer is
retained at a time, so your camera package's buffer pool is never starved.

**Android.** All `SurfaceView` copies are issued in parallel and the window is read back once.
Encoding happens off the UI thread.

## Example app

`example/` is a React Native 0.81 app that demonstrates every API, including a video player
forced onto a `SurfaceView` so you can see the compositing actually working.

```sh
yarn                    # in the repo root
cd example && yarn
yarn android            # or: yarn ios  (pod install first)
```

## Migrating from 1.x

The 1.x API still works but is deprecated and will be removed in 3.0.

| 1.x | 2.x |
| --- | --- |
| `screenCapture(cb, isHiddenStatus, options)` | `await capture({ excludeStatusBar, ...options })` |
| `startListener(cb, keywords)` | `addScreenshotListener(cb)` |
| `stopListener()` | `subscription.remove()` |
| `clearCache(cb)` | `await clearCache()` |
| result `{ code: '200', uri, base64 }` | resolves `{ uri, width, height }`, rejects on failure |

Other changes:

- Callbacks are gone; everything is a promise that rejects with a real error instead of
  resolving `{ code: '500' }`.
- `base64` is opt-in via `includeBase64`. It was always computed before, which doubled the cost
  of every capture.
- The `keywords` argument for screenshot detection is gone. Android 14+ uses the platform
  callback, and the pre-14 fallback uses a built-in keyword list.
- Minimum React Native is 0.76, minimum Android API is 24, minimum iOS is 15.1.
- The iOS status bar snapshot hack is gone. It swizzled the private `UIStatusBar` class, which
  stopped existing in iOS 13 — it had not worked for years and was an App Store review risk.

## License

MIT
