import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

val allowDebugSigning = System.getenv("ALLOW_DEBUG_SIGNING") == "true"

val localProperties = Properties().apply {
    val file = rootProject.file("local.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val androidSdkPath = System.getenv("ANDROID_SDK_ROOT")
    ?: System.getenv("ANDROID_HOME")
    ?: localProperties.getProperty("sdk.dir")
    ?: throw GradleException("找不到 Android SDK；请配置 ANDROID_HOME 或 android/local.properties。")
val hostOs = System.getProperty("os.name").lowercase()
val ndkHostTag = when {
    hostOs.contains("windows") -> "windows-x86_64"
    hostOs.contains("linux") -> "linux-x86_64"
    else -> throw GradleException("Android 正式构建仅支持 Windows 或 Linux 构建主机。")
}
val linkerSuffix = if (hostOs.contains("windows")) ".cmd" else ""
val rustWorkspace = rootProject.projectDir.parentFile.resolve("huse-vpn-next")

android {
    namespace = "com.one.huaji"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.one.huaji"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Android 8.0 (API 26) is the minimum supported platform. This is
        // also the first Android version used by the mobile VPN service.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            val storeFilePath = keystoreProperties.getProperty("storeFile")
            val storePassword = keystoreProperties.getProperty("storePassword")
            val keyAlias = keystoreProperties.getProperty("keyAlias")
            val keyPassword = keystoreProperties.getProperty("keyPassword")
            val hasReleaseKeystore = listOf(
                storeFilePath,
                storePassword,
                keyAlias,
                keyPassword,
            ).all { !it.isNullOrBlank() }

            if (hasReleaseKeystore) {
                val releaseSigning = signingConfigs.maybeCreate("release")
                releaseSigning.storeFile = file(storeFilePath!!)
                releaseSigning.storePassword = storePassword
                releaseSigning.keyAlias = keyAlias
                releaseSigning.keyPassword = keyPassword
                signingConfig = releaseSigning
            } else if (allowDebugSigning) {
                // 仅供本地内测；正式构建绝不能依赖 Debug 证书。
                signingConfig = signingConfigs.getByName("debug")
            } else {
                throw GradleException(
                    "正式 Android Release 需要 android/key.properties 中的独立 release keystore；" +
                        "若只是内测，请显式设置 ALLOW_DEBUG_SIGNING=true。",
                )
            }
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

// 每次 Android 构建都先核对 Rust 源码并同步对应 ABI 的原生库，避免把旧 .so
// 误装进新 APK。Cargo 自己负责增量编译，因此源文件未变化时开销很小。
val rustAndroidBuildTasks = listOf(
    Triple("Arm64", "aarch64-linux-android", "arm64-v8a"),
    Triple("ArmV7", "armv7-linux-androideabi", "armeabi-v7a"),
    Triple("X64", "x86_64-linux-android", "x86_64"),
).map { (taskSuffix, rustTarget, androidAbi) ->
    tasks.register<Exec>("buildRustAndroid$taskSuffix") {
        group = "build"
        description = "Build and sync huse-vpn-mobile-ffi for $androidAbi"
        workingDir(rustWorkspace)

        val linkerTarget = if (rustTarget == "armv7-linux-androideabi") {
            "armv7a-linux-androideabi"
        } else {
            rustTarget
        }
        val linker = File(
            androidSdkPath,
            "ndk/${flutter.ndkVersion}/toolchains/llvm/prebuilt/$ndkHostTag/bin/" +
                "${linkerTarget}26-clang$linkerSuffix",
        )
        val archiver = File(
            androidSdkPath,
            "ndk/${flutter.ndkVersion}/toolchains/llvm/prebuilt/$ndkHostTag/bin/" +
                "llvm-ar${if (hostOs.contains("windows")) ".exe" else ""}",
        )
        val builtLibrary = rustWorkspace.resolve(
            "target/$rustTarget/release/libhuse_vpn_mobile_ffi.so",
        )
        val packagedLibrary = project.file(
            "src/main/jniLibs/$androidAbi/libhuse_vpn_mobile_ffi.so",
        )

        inputs.files(
            rustWorkspace.resolve("Cargo.toml"),
            rustWorkspace.resolve("Cargo.lock"),
            rustWorkspace.resolve("core/Cargo.toml"),
            rustWorkspace.resolve("mobile-ffi/Cargo.toml"),
            fileTree(rustWorkspace.resolve("core/src")),
            fileTree(rustWorkspace.resolve("mobile-ffi/src")),
        )
        inputs.property("rustTarget", rustTarget)
        inputs.property("ndkVersion", flutter.ndkVersion)
        outputs.file(packagedLibrary)

        doFirst {
            if (!linker.isFile) {
                throw GradleException("找不到 Android NDK linker：${linker.absolutePath}")
            }
            if (!archiver.isFile) {
                throw GradleException("找不到 Android NDK archiver：${archiver.absolutePath}")
            }
            packagedLibrary.parentFile.mkdirs()
        }
        val normalizedRustTarget = rustTarget.replace('-', '_')
        environment(
            "CARGO_TARGET_${normalizedRustTarget.uppercase()}_LINKER",
            linker.absolutePath,
        )
        environment("CC_$normalizedRustTarget", linker.absolutePath)
        environment("AR_$normalizedRustTarget", archiver.absolutePath)
        commandLine(
            if (hostOs.contains("windows")) "cargo.exe" else "cargo",
            "build",
            "--package",
            "huse-vpn-mobile-ffi",
            "--release",
            "--target",
            rustTarget,
        )
        doLast {
            if (!builtLibrary.isFile) {
                throw GradleException("Rust 构建未生成：${builtLibrary.absolutePath}")
            }
            builtLibrary.copyTo(packagedLibrary, overwrite = true)
        }
    }
}

tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("JniLibFolders")) {
        dependsOn(rustAndroidBuildTasks)
    }
}
