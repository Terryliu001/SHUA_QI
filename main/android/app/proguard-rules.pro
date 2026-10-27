# R8 / ProGuard 规则
#
# 2026-10-27：release 包启动即崩（profile 正常），根因是 R8 把 ML Kit 的
# 组件注册器无参构造裁掉了：
#   Unable to get provider androidx.startup.InitializationProvider
#   Caused by: NoSuchMethodException:
#     com.google.mlkit.vision.digitalink.recognition.internal.DigitalInkRecognitionRegistrar.<init> []
#   ... CommonComponentRegistrar / VisionCommonRegistrar
# ML Kit 用反射按类名 newInstance()，必须整包保留。

# ---- ML Kit（手写识别 / Vision / Common）----
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_digital_ink.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text.** { *; }

# ---- 反射实例化的组件注册器（无参构造必须留着）----
-keep class * implements com.google.firebase.components.ComponentRegistrar { *; }
-keepclassmembers class * implements com.google.firebase.components.ComponentRegistrar {
    <init>();
}

# ---- WorkManager / androidx.startup（由 InitializationProvider 反射加载）----
-keep class androidx.startup.** { *; }
-keep class androidx.work.** { *; }

# ---- 告警抑制 ----
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**
-dontwarn com.google.firebase.**
