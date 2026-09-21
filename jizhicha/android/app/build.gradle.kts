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

// 签名凭据：环境变量优先（CI 用），key.properties 仅作本地兼容回退，
// 且按新约定只放非敏感的 storeFile / keyAlias。
// 在这里（而不是在 buildTypes.release 内部）求值，是为了让「缺密钥」只在
// 真的要打包 release 时才报错 —— 否则连 `flutter analyze`、单元测试、
// `assembleDebug` 都会在配置阶段直接失败。
fun signingSecret(env: String, property: String): String? =
    System.getenv(env)?.takeIf { it.isNotBlank() }
        ?: keystoreProperties.getProperty(property)?.takeIf { it.isNotBlank() }

val releaseStoreFile = signingSecret("JIZHICHA_KEYSTORE_FILE", "storeFile")
val releaseStorePassword = signingSecret("JIZHICHA_STORE_PASSWORD", "storePassword")
val releaseKeyAlias = signingSecret("JIZHICHA_KEY_ALIAS", "keyAlias")
val releaseKeyPassword = signingSecret("JIZHICHA_KEY_PASSWORD", "keyPassword")
val hasReleaseKeystore = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val debugSigningAllowed = allowDebugSigning && System.getenv("CI").isNullOrBlank()

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
val rustRemapFlags = listOf(
    "--remap-path-prefix=${rustWorkspace.absolutePath}=huse-vpn-next",
    "--remap-path-prefix=${System.getProperty("user.home")}=user-home",
).joinToString("\u001f")

android {
    namespace = "com.one.huaji"
    // 编译目标显式升到 37（Android 17）：只影响编译期能看到哪些 API 与弃用告警，
    // 不改变运行时行为。Flutter 3.44.8 默认仍是 36，所以这里不跟默认走。
    compileSdk = 37
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
        // 运行时 targetSdk 刻意保持 Flutter 默认（当前 36），不跟着 compileSdk 升到 37。
        // Android 17 对 targetSdk 37 的应用有若干**强制**行为变更（RemoteViews 位图内存
        // 上限超限直接崩溃、新增 ACCESS_LOCAL_NETWORK 运行时权限、后台音频限制等），
        // 必须先在 Android 17 真机逐项回归通过再升，否则升级动作本身就会引入崩溃。
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 「缺密钥」的报错移到下面的 taskGraph 校验里：只在真的要打包 release
            // 时才失败，避免配置阶段就炸掉 analyze / 单测 / assembleDebug。
            if (hasReleaseKeystore) {
                val releaseSigning = signingConfigs.maybeCreate("release")
                releaseSigning.storeFile = file(releaseStoreFile!!)
                releaseSigning.storePassword = releaseStorePassword
                releaseSigning.keyAlias = releaseKeyAlias
                releaseSigning.keyPassword = releaseKeyPassword
                signingConfig = releaseSigning
            } else if (debugSigningAllowed) {
                // 仅本地内测；CI 与正式发布绝不静默使用 Debug 证书。
                signingConfig = signingConfigs.getByName("debug")
            }
            // 其余情况：保持未签名。真正打包 release 时由下面校验报错。
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

// 只有真的要产出 release 包时才要求签名凭据。
// 这样 `flutter analyze`、`testDebugUnitTest`、`assembleDebug` 在没有密钥的
// 干净 checkout / CI 上也能正常工作。
gradle.taskGraph.whenReady {
    val packagingRelease = allTasks.any { task ->
        task.project.path == project.path &&
            (
                task.name.startsWith("assembleRelease") ||
                    task.name.startsWith("bundleRelease") ||
                    task.name.startsWith("packageRelease")
                )
    }
    if (packagingRelease && !hasReleaseKeystore && !debugSigningAllowed) {
        throw GradleException(
            "正式 Android Release 需要 JIZHICHA_* signing 环境变量或 " +
                "android/key.properties 中的独立 release keystore；" +
                "CI 中禁止 ALLOW_DEBUG_SIGNING。",
        )
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // JVM 单测只覆盖纯函数（提醒时刻/跨周换算/格式解析），不依赖设备或 Android 框架。
    testImplementation("junit:junit:4.13.2")
    // Android 的 android.jar 里 org.json 是「抛异常的空壳」，单测里必须换成
    // 真实实现，否则 JSONObject 一构造就抛 "not mocked"。
    testImplementation("org.json:json:20250107")
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
        inputs.property("rustRemapFlags", rustRemapFlags)
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
        environment("CARGO_ENCODED_RUSTFLAGS", rustRemapFlags)
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

// ==================== 只打包真机 arm64 ====================
//
// 用户要求：只发 arm64 真机包，不发布模拟器版本。
//
// ⚠️ 为什么需要这段：`flutter build apk --target-platform android-arm64`
// **不够** —— 它只限制 Flutter 自己的 libflutter/libapp，而：
//   - Rust 产物 `jniLibs/*/libhuse_vpn_mobile_ffi.so` 有三套 ABI；
//   - ONNX Runtime 的预编译 AAR 自带 arm64-v8a / armeabi-v7a / x86 / x86_64；
// 两者都会在 merge 阶段被无条件并进 APK。实测三套 ABI 全在（84MB）。
//
// 也试过另外两种写法，都不行：
//   - `defaultConfig.ndk.abiFilters`：AGP 9 下不参与 merge 过滤；
//   - `splits.abi`：与 Flutter Gradle 插件已设的 abiFilters 直接冲突
//     （EvalIssueException: Conflicting configuration）。
//   - `androidComponents.onVariants { it.ndk.abiFilters }`：AGP 9 新 DSL 里
//     没有 `ndk` 属性（Unresolved reference）。
//
// 因此改为在 merge 之后、打包之前**删除非 arm64 的 so 目录**。
// 这样与 AGP 版本无关，且不触碰 Flutter/插件的既有配置。
//
// ⚠️ 注意：必须挂到 `merge*NativeLibs`（而不是 JniLibFolders），
// 因为 ONNX 的 so 是在 NativeLibs 阶段才从 AAR 解出来的。
val keepAbis = setOf("arm64-v8a")

fun stripNonArm64NativeLibs(dir: File) {
    val jniRoot = File(dir, "out/lib")
    if (!jniRoot.isDirectory) return
    jniRoot.listFiles()?.forEach { abiDir ->
        if (abiDir.isDirectory && abiDir.name !in keepAbis) {
            abiDir.deleteRecursively()
        }
    }
}

// 只保留 arm64：在 merge 之后、打包之前删掉其它 ABI 的 so。
//
// 实际目录形如：
//   build/app/intermediates/merged_native_libs/release/mergeReleaseNativeLibs/out/lib/<abi>/
// 这里直接从任务自己的输出目录推导，避免手写路径出错。
tasks.configureEach {
    if (name.startsWith("merge") && name.endsWith("NativeLibs")) {
        doLast {
            val taskDir = layout.buildDirectory
                .dir("intermediates/merged_native_libs/release/$name")
                .get().asFile
            val jniRoot = File(taskDir, "out/lib")
            logger.lifecycle("[abi-filter] $name -> ${jniRoot.absolutePath} exists=${jniRoot.isDirectory}")
            if (!jniRoot.isDirectory) return@doLast
            jniRoot.listFiles()?.forEach { abiDir ->
                if (abiDir.isDirectory && abiDir.name !in keepAbis) {
                    logger.lifecycle("[abi-filter] removing ${abiDir.name}")
                    abiDir.deleteRecursively()
                }
            }
        }
    }
}
