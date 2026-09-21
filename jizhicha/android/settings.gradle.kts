pluginManagement {
    // Clean checkout / CI must not require a developer-specific local.properties.
    // Resolution priority: Gradle property -> environment -> optional local file.
    // `local.properties` remains supported for Android Studio, but is never committed.
    val localFlutterSdkPath = runCatching {
        val properties = java.util.Properties()
        val local = file("local.properties")
        if (!local.isFile) null else {
            local.inputStream().use { properties.load(it) }
            properties.getProperty("flutter.sdk")
        }
    }.getOrNull()
    val flutterSdkPath =
        providers.gradleProperty("flutter.sdk").orNull
            ?: System.getenv("FLUTTER_ROOT")
            ?: System.getenv("FLUTTER_SDK")
            ?: localFlutterSdkPath
            ?: error(
                "Flutter SDK not configured. Set FLUTTER_ROOT/FLUTTER_SDK, " +
                    "pass -Pflutter.sdk=<path>, or create android/local.properties.",
            )

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")
