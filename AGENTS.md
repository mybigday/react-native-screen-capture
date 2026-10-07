# Working on this repo

## Capture invariants

- Android copies each SurfaceView into its own ViewOverlay before window readback.
- iOS pulls AVFoundation frames into a temporary child of the media layer, below existing
  children, so masks, transforms and controls retain their ordering.
- In-process Metal/OpenGL content needs no frame provider.
- Serialize capture and provider lifecycle changes; retain native-owned buffers until callbacks
  finish, including callbacks arriving after a timeout.
- Preserve unknown capture options when forwarding to native.

## Build and platform checks

- Simulator hierarchy snapshots can include AVFoundation planes natively. Verify media
  compositing on hardware with a control capture that skips the placeholder path.
- Do not add `unstable_conditionNames: ['source', …]` to `example/metro.config.js`; it changes
  resolution globally. Verify that a bundled app boots.
- Read Android Window/View/inset state on the UI thread. The pre-API-34 screenshot detector
  also requires start/stop calls on the UI thread.
- Android accessibility capture uses display status-bar dimensions, not Activity insets.
- PixelCopy's SurfaceView overload is API 24; Rect/Window overloads are API 26. Check the
  SDK's `api-versions.xml` when changing availability guards.
- Android autolinking caches the package list. Regenerate its output after package renames.
- Release APKs embed JS; debug APKs require Metro.
- RN 0.81's fmt 11.0.2 needs `FMT_USE_CONSTEVAL=0` with Xcode 26, or Xcode 16.
- Keep `RCT_NEW_ARCH_ENABLED` consistent between pod installation and builds.
- Verify binary timestamps when reusing Xcode derived data.

## Signing over SSH

Check keychain lock/access before treating `errSecInternalComponent` as a GUI-session issue.
Use an existing authorized unlock helper without printing credential arguments or output.
If a GUI security session is required, use a tmux server started from a GUI Terminal;
a server started over SSH inherits the SSH session. Send commands only when its pane is idle
and use a unique log filename per run.

## Hardware validation

Check that comparison builds take different paths. Inspect provider `hasFrame` and compare
raw PNG media regions; color counts distinguish rendered media from a uniform empty region.
Use `dumpHierarchy()` to distinguish an unmatched component from an unavailable frame.

Read only the test app's output:

```sh
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
  --domain-identifier <bundle-id> --user mobile \
  --source Library/Caches/react-native-screen-capture/<file>.png --destination ./out.png
adb shell run-as <package> cat cache/react-native-screen-capture/<file>.png > ./out.png
```

Wait for capture settlement before copying files. `devicectl info files` sorts by name,
not time. Android `am force-stop` disables a hosted accessibility service; use an ordinary
restart when testing that service. Sideload restrictions and setup are documented in README.
