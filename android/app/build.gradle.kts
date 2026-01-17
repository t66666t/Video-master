plugins {
    id("com.android.application")
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

android {
    namespace = "com.example.video_player_app"
    compileSdk = 36
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.video_player_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 34
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
            storeFile = file(keystoreProperties.getProperty("storeFile"))
            storePassword = keystoreProperties.getProperty("storePassword")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            signingConfig = signingConfigs.getByName("release")
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
