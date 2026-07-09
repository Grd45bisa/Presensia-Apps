# TFLite GPU delegate class is referenced by tflite_flutter but not bundled.
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
-dontwarn org.tensorflow.lite.**
-keep class org.tensorflow.lite.** { *; }

# Keep our Kotlin native classes referenced in Manifest or by MethodChannels
-keep class id.presensia.face_recognizer.** { *; }

# Keep generic type signatures for Gson reflection and annotations
-keepattributes *Annotation*,Signature,InnerClasses,EnclosingMethod

# Gson rules
-dontwarn com.google.gson.**
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keepclassmembers class * {
    @com.google.gson.annotations.SerializedName <fields>;
}

# Flutter Local Notifications rules
-keep class com.dexterous.flutterlocalnotifications.** { *; }
-dontwarn com.dexterous.flutterlocalnotifications.**
