import type { TurboModule } from 'react-native'
import { TurboModuleRegistry } from 'react-native'
import type { UnsafeObject } from 'react-native/Libraries/Types/CodegenTypes'

/**
 * Options and results cross the bridge as plain objects on purpose.
 *
 * Declaring them as codegen structs makes codegen emit a C++ type on iOS
 * (`JS::NativeScreenCapture::NativeCaptureOptions &`), which forces the module to be Obj-C++
 * and to carry a separate old-architecture implementation. The public API in `index.ts` is
 * fully typed either way, so the only thing lost is codegen-side validation of an internal
 * boundary.
 *
 * See `CaptureOptions` / `CaptureResult` in `./index` for the real shapes.
 */
export interface Spec extends TurboModule {
  capture(options: UnsafeObject): Promise<UnsafeObject>

  /** Resolves to a PermissionStatus string. */
  getPermissionStatus(mode: string): Promise<string>
  requestPermission(mode: string): Promise<string>
  openAccessibilitySettings(): Promise<boolean>
  isModeAvailable(mode: string): Promise<boolean>

  /** Frame-provider lifecycle (iOS). No-op elsewhere. */
  warmUp(): Promise<void>
  coolDown(): Promise<void>

  /** Returns the number of files removed. */
  clearCache(): Promise<number>

  startScreenshotDetection(): Promise<void>
  stopScreenshotDetection(): Promise<void>

  /** __DEV__ helper: dumps the view/layer tree so new media components can be identified. */
  dumpHierarchy(): Promise<string>

  addListener(eventName: string): void
  removeListeners(count: number): void
}

export default TurboModuleRegistry.getEnforcing<Spec>('ScreenCapture')
