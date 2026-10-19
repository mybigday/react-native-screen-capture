import { AppState, NativeEventEmitter, NativeModules, Platform } from 'react-native'
import NativeScreenCapture from './NativeScreenCapture'

export type CaptureMode = 'auto' | 'view' | 'accessibility'

export type PermissionStatus =
  /** Ready to capture in this mode. */
  | 'granted'
  /** The user has to act (Android: enable the accessibility service). */
  | 'denied'
  /** This mode does not exist on this platform / OS version. */
  | 'unavailable'

export type CaptureOptions = {
  /**
   * `view` (default) captures this app's own windows. No permissions, no notification,
   * but it cannot see other apps or the real system bars.
   *
   * `accessibility` (Android, API 30+) captures the whole display. Requires the user to
   * enable an accessibility service once — see the README before shipping it.
   *
   * `auto` uses `accessibility` when it is already enabled, otherwise `view`.
   */
  mode?: CaptureMode
  /** Crop the status bar out of the result. Defaults to false. */
  excludeStatusBar?: boolean
  extension?: 'png' | 'jpg' | 'jpeg'
  /** JPEG quality, 1-100. Ignored for PNG. Defaults to 100. */
  quality?: number
  /** Output scale factor. Defaults to 1 (native size). */
  scale?: number
  /** Also return the image as base64. Costs an extra encode -- off by default. */
  includeBase64?: boolean
  /**
   * Which screen to capture when the app is driving more than one.
   *
   * `all` (default) stitches every screen the app is showing on, side by side, in one image --
   * an app whose content lives on an external display is captured, not the empty window left
   * behind on the built-in one. `main` captures only the built-in screen. A numeric string
   * selects a screen index on iOS, or a display ID on Android accessibility mode.
   *
   * Single-screen devices are unaffected: every value produces the same one screen.
   */
  screen?: 'all' | 'main' | (string & {})
  /**
   * Draw a labelled box over any region this library cannot capture, instead of leaving it
   * blank. Off by default.
   *
   * The label goes into the component's own layer tree, so anything drawn above it on screen
   * covers the label too -- z-order, clipping and transforms behave exactly as they do for a
   * captured frame.
   *
   * Marked today: DRM-protected video, a capture session that refused an output, an
   * `AVSampleBufferDisplayLayer` below iOS 17.4, and Android surfaces whose read-back the
   * system refuses (`SurfaceView`s flagged secure).
   */
  markUnsupported?: boolean
}

export type CaptureResult = {
  /** `file://` URI in the app's cache directory. */
  uri: string
  base64?: string
  width: number
  height: number
}

export type ScreenshotEvent = {
  /** Present only when the platform hands us the user's screenshot file. */
  uri?: string
}

export type Subscription = { remove(): void }

const EVENT_SCREENSHOT = 'ScreenCapture'

// Track this module's subscriptions independently of other emitter users.
const active = new Set<object>()
let detectionStarted = false
let detectionWork: Promise<void> = Promise.resolve()

// Serialize detection transitions; failed starts remain retryable.
function reconcileDetection(): void {
  detectionWork = detectionWork.then(async () => {
    try {
      if (active.size > 0 && !detectionStarted) {
        await NativeScreenCapture.startScreenshotDetection()
        detectionStarted = true
      } else if (active.size === 0 && detectionStarted) {
        await NativeScreenCapture.stopScreenshotDetection()
        detectionStarted = false
      }
    } catch { /* A later subscription/foreground transition retries the operation. */ }
  })
}

const emitter = new NativeEventEmitter(
  // The TurboModule object is a valid emitter target on the new architecture;
  // the bridge module is what NativeEventEmitter wants on the old one.
  (NativeModules.ScreenCapture ?? NativeScreenCapture) as any,
)

let defaultMode: CaptureMode = 'auto'

// Share pending probes only; service availability can change while foreground.
let accessibilityStatus: Promise<PermissionStatus> | null = null
AppState.addEventListener('change', (state) => {
  if (state === 'active') {
    accessibilityStatus = null
    reconcileDetection()
  }
})

async function resolveMode(mode: CaptureMode): Promise<'view' | 'accessibility'> {
  if (mode !== 'auto') return mode
  if (Platform.OS !== 'android') return 'view'
  if (accessibilityStatus === null) {
    const probe = (
      NativeScreenCapture.getPermissionStatus('accessibility') as Promise<PermissionStatus>
    ).catch(() => 'denied' as PermissionStatus)
    accessibilityStatus = probe
    void probe.then(() => {
      if (accessibilityStatus === probe) accessibilityStatus = null
    })
  }
  return (await accessibilityStatus) === 'granted' ? 'accessibility' : 'view'
}

/** Set the mode used when `capture()` is called without an explicit one. */
export function setMode(mode: CaptureMode): void {
  defaultMode = mode
}

export function getMode(): CaptureMode {
  return defaultMode
}

export async function capture(options: CaptureOptions = {}): Promise<CaptureResult> {
  if (!Number.isFinite(options.scale ?? 1) || (options.scale ?? 1) <= 0) {
    throw new Error('scale must be a finite positive number')
  }
  if (!Number.isFinite(options.quality ?? 100)) {
    throw new Error('quality must be finite')
  }
  const mode = await resolveMode(options.mode ?? defaultMode)
  // Preserve unknown native options; explicit values override defaults.
  const result = await NativeScreenCapture.capture({
    excludeStatusBar: false,
    extension: 'png',
    quality: 100,
    scale: 1,
    includeBase64: false,
    ...options,
    mode,
  })
  return result as CaptureResult
}

export function getPermissionStatus(mode: CaptureMode = 'view'): Promise<PermissionStatus> {
  return NativeScreenCapture.getPermissionStatus(mode) as Promise<PermissionStatus>
}

export function requestPermission(mode: CaptureMode = 'view'): Promise<PermissionStatus> {
  accessibilityStatus = null
  return NativeScreenCapture.requestPermission(mode) as Promise<PermissionStatus>
}

/** Android only. Deep-links to system accessibility settings; resolves once it is opened. */
export function openAccessibilitySettings(): Promise<boolean> {
  return NativeScreenCapture.openAccessibilitySettings()
}

export function isModeAvailable(mode: CaptureMode): Promise<boolean> {
  return NativeScreenCapture.isModeAvailable(mode)
}

/**
 * Attach the frame providers ahead of time (iOS). Costs a little battery while attached,
 * but removes the one-frame delay on the first `capture()`. They detach themselves after
 * a few idle seconds, so this only matters if you are about to capture in a burst.
 */
export function warmUp(): Promise<void> {
  return NativeScreenCapture.warmUp()
}

export function coolDown(): Promise<void> {
  return NativeScreenCapture.coolDown()
}

/** Removes every file this module has written. Resolves with the count. */
export function clearCache(): Promise<number> {
  return NativeScreenCapture.clearCache()
}

/** Delete one result after its consumers finish. Returns false if it was already removed. */
export function releaseCapture(uri: string): Promise<boolean> {
  return NativeScreenCapture.releaseCapture(uri)
}

/** Fires when the *user* takes a screenshot. Does not fire for `capture()`. */
export function addScreenshotListener(
  listener: (event: ScreenshotEvent) => void,
): Subscription {
  const sub = emitter.addListener(EVENT_SCREENSHOT, listener)
  const token = {}
  active.add(token)
  reconcileDetection()
  return {
    remove: () => {
      if (!active.delete(token)) return
      sub.remove()
      reconcileDetection()
    },
  }
}

/**
 * Dumps the native view/layer tree. Use it to find out which class a media component
 * renders through when a new package is not being captured correctly.
 */
export function dumpHierarchy(): Promise<string> {
  return NativeScreenCapture.dumpHierarchy()
}

export default {
  capture,
  setMode,
  getMode,
  getPermissionStatus,
  requestPermission,
  openAccessibilitySettings,
  isModeAvailable,
  warmUp,
  coolDown,
  clearCache,
  releaseCapture,
  addScreenshotListener,
  dumpHierarchy,
}
