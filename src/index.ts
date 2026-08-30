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
  /** Also return the image as base64. Costs an extra encode — off by default. */
  includeBase64?: boolean
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

// Tracked here rather than asked of the emitter: `ScreenCapture` is a bare global device event,
// so emitter.listenerCount() also sees 1.x-era DeviceEventEmitter listeners and any second copy
// of this package -- which would keep native detection running after our last subscriber left.
// A set rather than a counter, so a subscription removed twice cannot drive the count past
// zero and stop detection under a listener that is still subscribed.
const active = new Set<object>()

const emitter = new NativeEventEmitter(
  // The TurboModule object is a valid emitter target on the new architecture;
  // the bridge module is what NativeEventEmitter wants on the old one.
  (NativeModules.ScreenCapture ?? NativeScreenCapture) as any,
)

let defaultMode: CaptureMode = 'auto'

// The accessibility service can only be switched on from system Settings, which means the app
// was backgrounded in between. Caching the answer keeps a burst of captures from paying a
// native round-trip each, which would otherwise sit in front of every single frame.
// The promise, not the resolved value: a burst that starts in one tick would otherwise see a
// null cache on every call and fire a round-trip each, which is what the cache is here to stop.
let accessibilityStatus: Promise<PermissionStatus> | null = null
AppState.addEventListener('change', (state) => {
  if (state === 'active') accessibilityStatus = null
})

async function resolveMode(mode: CaptureMode): Promise<'view' | 'accessibility'> {
  if (mode !== 'auto') return mode
  if (Platform.OS !== 'android') return 'view'
  if (accessibilityStatus === null) {
    accessibilityStatus = (
      NativeScreenCapture.getPermissionStatus('accessibility') as Promise<PermissionStatus>
    ).then(
      (status) => {
        // 'denied' also means "enabled, not bound yet", which is what the user sees for a
        // moment after flipping the toggle and coming back. Caching that would pin `auto` to
        // `view` for the rest of the foreground session.
        if (status === 'denied') accessibilityStatus = null
        return status
      },
      () => {
        // Nor cache a failure. `auto` is the mode a caller picks so they never have to think
        // about accessibility availability, so a failed probe falls back rather than rejecting
        // the capture they actually asked for.
        accessibilityStatus = null
        return 'denied' as PermissionStatus
      },
    )
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
  const mode = await resolveMode(options.mode ?? defaultMode)
  // Spread first, defaults after: rebuilding the object key by key dropped everything this
  // union does not name, which once turned an A/B test into two identical runs. Unknown keys
  // are the native side's business, not this function's.
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

/** Fires when the *user* takes a screenshot. Does not fire for `capture()`. */
export function addScreenshotListener(
  listener: (event: ScreenshotEvent) => void,
): Subscription {
  const sub = emitter.addListener(EVENT_SCREENSHOT, listener)
  const token = {}
  active.add(token)
  NativeScreenCapture.startScreenshotDetection().catch(() => {})
  return {
    remove: () => {
      if (!active.delete(token)) return
      sub.remove()
      if (active.size === 0) {
        NativeScreenCapture.stopScreenshotDetection().catch(() => {})
      }
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
  addScreenshotListener,
  dumpHierarchy,
}
