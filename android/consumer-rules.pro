# The accessibility service is referenced from the host app's manifest only,
# so R8 cannot see the reference and would otherwise strip it.
-keep class com.lewin.capture.ScreenCaptureAccessibilityService { *; }
