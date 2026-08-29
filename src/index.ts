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

const emitter = new NativeEventEmitter(
  // The TurboModule object is a valid emitter target on the new architecture;
  // the bridge module is what NativeEventEmitter wants on the old one.
  (NativeModules.ScreenCapture ?? NativeScreenCapture) as any,
)

let defaultMode: CaptureMode = 'auto'

// The accessibility service can only be switched on from system Settings, which means the app
// was backgrounded in between. Caching the answer keeps a burst of captures from paying a
// native round-trip each, which would otherwise sit in front of every single frame.
let accessibilityStatus: PermissionStatus | null = null
AppState.addEventListener('change', (state) => {
  if (state === 'active') accessibilityStatus = null
})

async function resolveMode(mode: CaptureMode): Promise<'view' | 'accessibility'> {
  if (mode !== 'auto') return mode
  if (Platform.OS !== 'android') return 'view'
  if (accessibilityStatus === null) {
    accessibilityStatus = (await NativeScreenCapture.getPermissionStatus(
      'accessibility',
    )) as PermissionStatus
  }
  return accessibilityStatus === 'granted' ? 'accessibility' : 'view'
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
  const result = await NativeScreenCapture.capture({
    mode,
    excludeStatusBar: options.excludeStatusBar ?? false,
    extension: options.extension ?? 'png',
    quality: options.quality ?? 100,
    scale: options.scale ?? 1,
    includeBase64: options.includeBase64 ?? false,
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

/**
 * Removes every file this module has written. Resolves with the count.
 *
 * `callback` exists for 1.x callers, which passed one instead of using the promise. It gets
 * 1.x's `{ code }` object -- `'200'` or `'500'` -- plus the count. New code should await the
 * promise, which is the only place the count is meaningful on its own.
 */
export function clearCache(
  callback?: (result: { code: string; count: number }) => void,
): Promise<number> {
  const promise = NativeScreenCapture.clearCache()
  if (!callback) return promise
  // 1.x reported failure through the same callback and had no promise to catch, so the one
  // returned here must not reject either.
  return promise.then(
    (count) => {
      callback({ code: '200', count })
      return count
    },
    () => {
      callback({ code: '500', count: 0 })
      return 0
    },
  )
}

/** Fires when the *user* takes a screenshot. Does not fire for `capture()`. */
export function addScreenshotListener(
  listener: (event: ScreenshotEvent) => void,
): Subscription {
  const sub = emitter.addListener(EVENT_SCREENSHOT, listener)
  NativeScreenCapture.startScreenshotDetection().catch(() => {})
  return {
    remove: () => {
      sub.remove()
      if (emitter.listenerCount(EVENT_SCREENSHOT) === 0) {
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

/** @deprecated Use `capture()`. */
export function screenCapture(
  callback: (result: Partial<CaptureResult> & { code: string }) => void,
  excludeStatusBar?: boolean,
  options?: CaptureOptions,
): void {
  capture({
    ...options,
    // 1.x only honoured this argument when it was actually passed, and defaulted to true on
    // Android. Spreading `options` and then writing an undefined over it would have made the
    // default false on both platforms.
    excludeStatusBar: excludeStatusBar ?? options?.excludeStatusBar ?? Platform.OS === 'android',
    // 1.x spelled "native size" as scale 0; capture() spells it 1.
    scale: options?.scale || 1,
    includeBase64: true,
  })
    .then((r) => callback({ ...r, code: '200' }))
    .catch(() => callback({ code: '500' }))
}

/**
 * @deprecated Use `addScreenshotListener()`. **The event payload is not 1.x-compatible.**
 *
 * 1.x delivered `{ code, uri, base64 }`. This delivers `{ uri }` on Android and `{}` on iOS:
 * the platform screenshot callbacks hand over no image, and decoding the user's screenshot
 * just to fill `base64` in would cost a full read and encode on every screenshot. Handlers
 * that used `base64` need to call `capture()` themselves.
 *
 * The 1.x `keyWords` argument is accepted and ignored: detection no longer matches on file names.
 */
export function startListener(
  callback: (event: ScreenshotEvent) => void,
  _keyWords?: string,
): Subscription {
  return addScreenshotListener(callback)
}

/** @deprecated Remove the subscription returned by `addScreenshotListener()` instead. */
export function stopListener(): Promise<void> {
  emitter.removeAllListeners(EVENT_SCREENSHOT)
  return NativeScreenCapture.stopScreenshotDetection()
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
  screenCapture,
  startListener,
  stopListener,
}
