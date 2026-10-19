# The Flutter engine is reached from native code and by reflection, so R8 cannot
# see those references and would strip the entry points out of a shrunk build.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Play Core is referenced by the engine's deferred-components support but is not
# a dependency of this app, so R8 reports the missing classes as errors.
-dontwarn com.google.android.play.core.**

# webrtc-sdk 150 reaches jni_zero from native code and names a class that is generated at native build time.
-keep class org.jni_zero.** { *; }
-dontwarn org.jni_zero.JniZeroJni
