# Capture failure recovery

This change addresses independent render, provider lifecycle, encoding and storage failure
paths. It does not establish a single cause for every black screenshot report.

- iOS window rendering uses a transparent intermediate surface so a transparent secondary
  window cannot replace earlier content with an opaque black background. Final composition
  remains opaque; `afterScreenUpdates:YES` is unchanged.
- Media providers identify the presentation as well as its player/session. Discovery is
  revalidated after the frame wait, and a changed presentation rejects for a caller retry.
  Camera previews share a session reader while keeping separate presentation targets.
- Replacement media pixels and unsupported markers are inserted inside the original media
  layer, below its existing children. Core Animation retains transforms, opacity, arbitrary
  masks and control ordering for both view-backing and internal media layers.
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
filesystem operations with safe injected failures. Initial checks covered five JS lifecycle groups,
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

The combined core candidate also completed a separate 600-capture signed iOS-on-Mac
matrix. Controlled secondary-window visibility caused 60/120 whole-black baseline images
and 0/120 candidate images. During 180 sustained AV captures per variant, the baseline
lost media at the two remount instants; the candidate had no missing media region.
This covers controlled visibility and remounts, not natural sleep/focus/display transitions.

Subsequent full React Native 0.81 application runs on the physical iPhone and iOS-on-Mac
covered both architectures: 41 JS/API checks per run, 600 new-architecture and 120
legacy encode/decode/release cycles per device, and three actual runtime reloads per run
while an encoder write was delayed. Each sampled/final owned-cache count was zero.
Those bounded resource samples do not exclude leaks or establish that every loop image
was visually correct. The runs preceded the final media-layer insertion correction.

Physical-iPhone geometry comparisons then exposed leaked video outside a triangle mask
and video covering controls on a view-backing AVPlayerLayer. Both issues also required
checking an internal media layer. Inserting replacement pixels inside the media layer
passed the same 14-image comparisons for both structures; the original 3.1 renderer
failed the independent expected-color checks. The fixture exercises normal, 90/180-degree
rotation, rounded corners, opacity, a changed anchor and a triangle mask. The pixel
checker validates visible controls and clipping in the documented samples, not every
video pixel or every possible transform.

After that correction, full new-architecture React Native AV remount/lifecycle runs again
passed 30 captures per device, plus a recovery capture in the same process. The iPhone
entered background and returned to foreground; the Mac lost and regained focus. A
separate Mac run before the correction verified actual minimize/restore and read back a
successful capture. Physical VLC native-core playback/readback was also exercised.

On the physical iPhone, two distinct preview layers in a real AVCaptureMultiCamSession
passed 11 reader/delegate/ownership checks using manually fed CoreVideo samples. This
does not validate a live camera sensor. A subsequent full RN check on both devices
composited manually fed samples into two real preview layers and decoded two PNGs per
device, with distinct media regions and restored host delegate/queue after cooldown.
Raw images retained the triangle clip and visible controls; the Mac control color was
near cyan rather than byte-exact cyan. No sensor inputs or running session were used.
Android old/new
architecture example APKs built successfully; their DEX superclasses were checked.
The complete native tvOS fixture compiled and linked without signing or installation.
It also compiled and linked against the tvOS Simulator SDK. A corrected read-only
`simctl list devices available --json` query found three existing tvOS 26.5 simulators,
all shut down at inventory time. An existing Apple TV 4K third-generation 1080p
simulator then ran a uniquely identified synthetic fixture: two static, eight AV and
twelve same-player remount captures completed without callback errors or whole-black
images. All post-remount provider frames targeted the new host. The fixture was removed
and the simulator returned to its original shutdown state. File-based fixture output
completed after an initial console-streaming run timed out; that partial evidence was
retained. This is native-core simulator coverage, not physical tvOS media evidence.

Still required: live camera capture with a controlled chart, physical Android/tvOS runtime
tests, sleep/lock recovery, external-display transitions and simultaneous OS-screen
readback. Only one physical Mac display was available. The installed BRICKS versions
differed from the reported failing build, so these fixtures do not establish that the
reported application regression is fixed. Injected storage errors and bounded memory
runs do not exclude every real disk-full, OOM or resource failure.


## Follow-up failure-mode audit

A later audit adds fixes for independently reproduced failures:

- Choose the key window (otherwise the largest visible window) for the viewport independently
  from composition order. Revalidate that choice after waiting for media. A 1×1 low-level
  auxiliary window previously clipped a full-window capture to 2×2 pixels.
- Insert media replacements below negative-z children too. A physical-iPhone control at z=-1
  was visible in a direct UIKit snapshot but covered by the library; all 14 geometry samples
  passed after correction.
- Match camera readers and borrowed outputs by session and video input-port identity. Mixed
  outputs or unidentified live streams refuse attachment rather than returning another stream's
  pixels. Reader identifiers and registry ownership use the same initialization snapshot.
  Inputless synthetic sessions remain supported. Refused attachment no longer advances
  the generation; player detach keeps output ownership retryable while releasing its cached frame.
- Drain request-local encode autoreleases before resolving/rejecting callbacks; validate rounded
  dimensions before allocation. iOS release and failed-write cleanup use leaf unlink, preserving
  a directory that replaces the file and its contents.
- Recover encoder admission if Android worker creation throws; clean up collected display images
  when continuation fails and tolerate cursor-close failures. Refresh completed foreground-service
  status probes so `auto` can fall back after the service disappears.
- Cap outstanding native PixelCopy destinations across captures at 64 million pixels and cap the
  aggregate SurfaceView destinations before allocating. A timeout does not make a native destination
  safe to recycle: its lease remains until completion. If native never completes, the budget stays
  reserved and subsequent requests fail closed. Overlay setup/cleanup is exception-safe with bounded
  removal retry. This is a destination budget, not a total process-memory or OOM guarantee.
- Android publication checks cache-directory, pending-file and opened-descriptor device/inode
  identities around writing and renaming. A controlled cache-directory replacement now rejects
  instead of publishing replacement bytes, and failed cleanup preserves unrelated replacements.
  The pending file opens in append mode so an identity mismatch cannot truncate replacement bytes
  before validation. These checks are not atomic against arbitrary concurrent host filesystem mutations.

Follow-up checks passed: six transpiled-JS groups; 133 filesystem, 11 request, 31 encoder,
20 display-continuation, eight cursor, 178 PixelCopy/overlay and 48 publication-identity JVM
checks; 321 Foundation/control-flow/CoreVideo checks; 40 camera-stream and 20 provider native
checks; and 16 Apple SDK syntax checks. Android legacy and new architecture compilation passed.
The AV framework behavior in the stream/provider probes is modeled; CoreVideo samples and the
Foundation filesystem are real. The JVM identity checker models the opened descriptor by a path
snapshot; production uses Android `fstat`, which has compile coverage here but needs runtime testing.

Physical XR tests also verified the viewport and negative-z regressions. An alpha-loss hypothesis
was withdrawn: byte-exact old/candidate scaling on UIKit retained transparency in both outputs.
The bounded probes do not establish every possible failure mode, a natural long-duration onset,
or absence of leaks. The earlier device results above retain their original source scope.


On the final iOS source, full RN new-architecture runs on XR and iOS-on-Mac each passed
41 API checks, 600 encode/decode/release cycles and three actual runtime reloads during delayed
writes. All sampled/final owned-cache counts were zero. Each platform also passed 30 AV captures
and same-process foreground/focus recovery, plus two manually fed camera composite PNGs with
host delegate/queue restoration. The 66 selected raw images decoded without whole-black output;
AV regions exceeded 500 distinct colors and camera control/mask samples matched fixture colors
(XR exact, Mac within 32 per RGB channel). These are bounded, synthetic own-app regressions;
they do not establish that the reported BRICKS 2.25.11 build is fixed or prove absence of leaks.
