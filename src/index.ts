import { NativeEventEmitter, NativeModules, Platform } from 'react-native'
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

async function resolveMode(mode: CaptureMode): Promise<'view' | 'accessibility'> {
  if (mode !== 'auto') return mode
  if (Platform.OS !== 'android') return 'view'
  const status = await NativeScreenCapture.getPermissionStatus('accessibility')
  return status === 'granted' ? 'accessibility' : 'view'
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
  callback: (result: CaptureResult & { code: string }) => void,
  excludeStatusBar?: boolean,
  options?: CaptureOptions,
): void {
  capture({ ...options, excludeStatusBar, includeBase64: true })
    .then((r) => callback({ ...r, code: '200' }))
    .catch(() => callback({ code: '500' } as any))
}

/** @deprecated Use `addScreenshotListener()`. */
export function startListener(callback: (event: ScreenshotEvent) => void): Subscription {
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
