plugins {
    id("com.android.application")
    id("com.chaquo.python")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
import java.io.FileInputStream

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

kotlin {
    jvmToolchain(21)
}

android {
    namespace = "com.example.video_player_app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    // kotlinOptions has been removed, using jvmToolchain instead


    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.video_player_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
            }
            // 关闭代码混淆和资源压缩，防止 Flutter 插件功能失效
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        debug {
            if (keystorePropertiesFile.exists()) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

chaquopy {
    defaultConfig {
        version = "3.11"
        buildPython("py", "-3.11")
        pip {
            // Keep the embedded Android runtime reproducible and in sync with
            // YtDlpVersions.androidBundled in Dart.
            install("yt-dlp==2026.8.19")
        }
    }
}

configurations.all {
    resolutionStrategy {
        val media3Version = "1.9.0"
        force("androidx.media3:media3-exoplayer:$media3Version")
        force("androidx.media3:media3-exoplayer-dash:$media3Version")
        force("androidx.media3:media3-exoplayer-hls:$media3Version")
        force("androidx.media3:media3-exoplayer-rtsp:$media3Version")
        force("androidx.media3:media3-exoplayer-smoothstreaming:$media3Version")
        force("androidx.media3:media3-datasource-cronet:$media3Version")
        force("androidx.media3:media3-session:$media3Version")
        force("androidx.media3:media3-extractor:$media3Version")
        force("androidx.media3:media3-common:$media3Version")
        force("androidx.media3:media3-ui:$media3Version")
        force("androidx.media3:media3-container:$media3Version")
        force("androidx.media3:media3-database:$media3Version")
        force("androidx.media3:media3-datasource:$media3Version")
        force("androidx.media3:media3-decoder:$media3Version")
    }
}

flutter {
    source = "../.."
}

// Ensure flutter assets are properly packaged
android.applicationVariants.all {
    val variant = this
    variant.outputs
        .map { it as com.android.build.gradle.internal.api.BaseVariantOutputImpl }
        .forEach { output ->
            output.outputFileName = "app-${variant.buildType.name}.apk"
        }
}
