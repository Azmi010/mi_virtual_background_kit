# Plugin entry points must survive R8 full mode.
-keep class com.azmi010.mi_virtual_background_kit.** { *; }

# MediaPipe calls framework classes from native code by name. Its own AAR rules
# cover most of them; these fill the gaps seen with R8 full mode.
-keep class com.google.mediapipe.framework.** { *; }
-keep class * extends com.google.protobuf.GeneratedMessageLite { *; }
-keep class com.google.common.flogger.** { *; }
-dontwarn com.google.common.flogger.**
-keep class com.google.android.datatransport.** { *; }
-dontwarn com.google.android.datatransport.**
-dontwarn com.google.mediapipe.**
-dontwarn com.google.protobuf.**
