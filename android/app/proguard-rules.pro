# TFLite GPU delegate class is referenced by tflite_flutter but not bundled.
-dontwarn org.tensorflow.lite.gpu.GpuDelegateFactory$Options
-dontwarn org.tensorflow.lite.**
-keep class org.tensorflow.lite.** { *; }

# Keep our Kotlin native classes referenced in Manifest or by MethodChannels
-keep class id.presensia.face_recognizer.** { *; }
