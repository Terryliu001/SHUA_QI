import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystoreFile = rootProject.file("key.properties")
if (keystoreFile.exists()) {
    FileInputStream(keystoreFile).use { keystoreProperties.load(it) }
}



android {
    namespace = "com.shuaqi.shuaqi"

    // 版本锁定（T0.1）：与 Flutter 3.47.6 模板默认值一致，对应已安装的 platforms;android-36。
    // 不要改成 37 —— Flutter 3.47.6 未对 API 37 做测试。
    compileSdk = 36

    // ndkVersion 暂不声明（T0.1）：当前无任何原生插件，声明后 AGP 可能自动下载约 1GB 的 NDK。
    // 等 T0.4/T0.5 引入带原生代码的插件（pdfrx / onnxruntime）时再打开，届时按 flutter.ndkVersion 单独确认安装。
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shuaqi.shuaqi"
        // minSdk 26：规格硬要求（Android 8.0）；模板默认是 24，必须显式抬高。
        minSdk = 26
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 不要在这里写 ndk { abiFilters }：实测无效。
        // Flutter 构建时会注入 -Ptarget-platform=android-arm,android-arm64,android-x64，
        // 它在 Gradle 侧覆盖这里的 abiFilters（2026-10-22 验证：加了之后 APK 仍含三个 ABI）。
        // 正确的收敛方式是命令行限定：flutter build apk --target-platform android-arm64
        // （flutter run 也支持同一参数），本项目目标设备是 arm64。
    }


    signingConfigs {
        if (keystoreFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }






    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName(if (keystoreFile.exists()) "release" else "debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
