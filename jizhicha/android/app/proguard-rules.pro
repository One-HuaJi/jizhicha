# ============================================================================
# 「稽之查」release 包 R8 keep 规则
# ============================================================================
#
# 生效位置：android/app/build.gradle.kts 的 release {} 块
#     isMinifyEnabled = true
#     isShrinkResources = true
#     proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),
#                   "proguard-rules.pro")
#
# 在此之前上面的开关从未被打开（`git log -S isMinifyEnabled` 在该文件里查不到
# 任何提交），所以本文件一直是**死配置**，release 包从未真正经过混淆与裁剪。
#
# 由此必须记住：debug 包不做混淆，「debug 能跑」完全不能证明这里写全了。
# 规则漏掉时的典型表现是**只在 release 真机上**出现的
# ClassNotFoundException / NoSuchMethodError / UnsatisfiedLinkError，而且像
# Manifest 组件改名这种问题还是静默失效、连崩溃日志都没有。
#
# ⚠️ 因果准确性（勿被早期交接文档误导）：历史上那次 Android OCR 闪退曾被归因于
# 「proguard 规则缺失」，但真实原因是 **OCR 会话单线程（intraOpNumThreads=1）
# 且关闭 CPU arena**，用来避开并发建会话时的原生竞态与内存峰值；修好它的时候
# R8 并未生效。所以下面第 1、2 组规则是「真正开启 R8 之后维持 OCR 可用」的
# 必要条件，而不是那次闪退的修复原因，更不能当成「已被验证」的结论。
# 接线 R8 后必须对 release 包重新回归 OCR 与 VPN。
#
# 另外：proguard-android-optimize.txt（AGP 9.0.1 随包提供，已核对其内容）本身
# 已经包含 `-keepclasseswithmembernames,includedescriptorclasses class * {
# native <methods>; }`、`-keepclassmembers enum * { values(); valueOf(String); }`、
# `-keepclassmembers class * implements android.os.Parcelable { CREATOR; }` 以及
# AnnotationDefault / EnclosingMethod / InnerClasses / Signature /
# RuntimeVisible*Annotations 等注解属性保留。下面凡是与它重复的条目都标注了
# 「与默认规则重复」，只写一次为了在发生混淆崩溃时本文件里就能自查，不做重复膨胀。
# ============================================================================


# ---------------------------------------------------------------------------
# 1. flutter_onnxruntime（验证码 OCR）
# ---------------------------------------------------------------------------
# 插件入口 com.masicai.flutteronnxruntime.FlutterOnnxruntimePlugin 由
# GeneratedPluginRegistrant 按**全名** new 出来，实例内用 ConcurrentHashMap 按
# 字符串 ID 持有 OrtSession / OnnxValue。
#
# 关键事实：onnxruntime-android AAR **不带 consumer proguard 规则**（已解包核对：
# onnxruntime-android-1.23.0.aar 内没有任何 .pro 文件），所以 ONNX 侧的保留
# 只能由本应用兜底，漏了没有第二道防线。
-keep class com.masicai.flutteronnxruntime.** { *; }
# native 方法要同时保住「名字 + 描述符」：C 侧 JNI 符号是
# Java_..._<方法名>__<参数描述符> 的形式，改名或改签名即 UnsatisfiedLinkError。
-keepclasseswithmembernames,includedescriptorclasses class com.masicai.flutteronnxruntime.** {
    native <methods>;
}

# ---------------------------------------------------------------------------
# 2. ONNX Runtime Java API（ai.onnxruntime）与 native 方法
# ---------------------------------------------------------------------------
# 覆盖 OCR 实际用到的类：OrtEnvironment、OrtSession（含 SessionOptions /
# RunOptions / Result）、OnnxTensor、OnnxValue、OnnxJavaType、OrtException、
# OrtLoggingLevel、providers.OrtTensorRTProviderOptions 等。
#
# 已核对该 AAR 的 classes.jar：只有 ai.onnxruntime、ai.onnxruntime.platform、
# ai.onnxruntime.providers 三个包，**不存在 org.onnxruntime 包**。
# 下面 org.onnxruntime.** 两条是防御性冗余（部分历史示例 / 其它 ONNX 绑定的
# 包名是 org.onnxruntime.*）：对不存在的类写 -keep 无副作用，既不影响体积也不
# 影响优化，将来换绑定时不必再踩一次。
-keep class ai.onnxruntime.** { *; }
-keepclasseswithmembernames,includedescriptorclasses class ai.onnxruntime.** {
    native <methods>;
}
-keep class org.onnxruntime.** { *; }
-keepclasseswithmembernames,includedescriptorclasses class org.onnxruntime.** {
    native <methods>;
}


# ---------------------------------------------------------------------------
# 3. 本项目 Kotlin 里的 external fun（VPN JNI）
# ---------------------------------------------------------------------------
# CampusVpnService.kt 声明了 4 个 external fun：
#     nativePrepare / nativeStatusJson / nativeStartTunnel / nativeDisconnect
# Rust 侧 libhuse_vpn_mobile_ffi.so 导出的符号形如
#     Java_com_one_huaji_CampusVpnService_nativePrepare
# 即 JNI 符号里**硬编码了完整类名与方法名**。R8 一改名，System.loadLibrary
# 仍然成功（.so 确实加载了），但第一次调用 native 方法就抛 UnsatisfiedLinkError，
# 表现为「VPN 点连接后直接失败」而不是启动即崩，非常容易误判成 Rust 侧问题。
# 因此类名、方法名、参数描述符三者都不能被改写。
-keep class com.one.huaji.CampusVpnService { *; }
-keepclasseswithmembernames,includedescriptorclasses class com.one.huaji.CampusVpnService {
    native <methods>;
}
# 通用兜底（与 proguard-android-optimize.txt 中的同名规则重复，保留是为了让
# 「JNI 依赖 native 方法名」这条约定在本文件内可见，并覆盖将来新增的 JNI 类）。
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}


# ---------------------------------------------------------------------------
# 4. jni / jni_flutter 插件
# ---------------------------------------------------------------------------
# 两者自带 consumer-rules.pro（-keep class com.github.dart_lang.jni.** 与
# com.github.dart_lang.jni_flutter.**），构建时会被自动并入，所以这里**不整包
# 重复保留**，只显式钉住两个插件注册入口类；万一将来插件升级/改名导致 consumer
# 规则失效，这两个入口也不会被裁掉（GeneratedPluginRegistrant 是按全名 new 的）。
-keep class com.github.dart_lang.jni.JniPlugin { *; }
-keep class com.github.dart_lang.jni_flutter.JniFlutterPlugin { *; }


# ---------------------------------------------------------------------------
# 5. Flutter 引擎
# ---------------------------------------------------------------------------
# io.flutter.** 被多处按类名访问：GeneratedPluginRegistrant、MethodChannel 的
# 反射、libflutter.so 从 native 侧回调 Java 等。Flutter 的 gradle 插件会注入
# flutter_proguard_rules.pro（其中带 -dontwarn io.flutter.plugin.** 等），但注入
# 内容随 SDK 版本变化；这里显式整包保留 io.flutter.**，保证换 Flutter 版本后
# 行为一致（代价是 Flutter 引擎类不被裁剪，属于官方推荐的稳妥做法）。
-keep class io.flutter.** { *; }
# 插件注册表由引擎按全名实例化，单独再钉一次以免被上游规则变更影响。
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }


# ---------------------------------------------------------------------------
# 6. org.json
# ---------------------------------------------------------------------------
# AppWidget.kt / CampusVpnService.kt 直接用 org.json.JSONObject 读写本地缓存
# （widget_schedule.json / widget_settings.json）与 VPN 状态 JSON。运行时实现来自
# 系统 bootclasspath（不是应用自带代码），整体保留的体积代价为零，同时避免
# R8 因字段/方法访问改写牵连到 JSON 解析路径。
-keep class org.json.** { *; }


# ---------------------------------------------------------------------------
# 7. 由系统按类名实例化的组件（AndroidManifest 里的字符串类名）
# ---------------------------------------------------------------------------
# 系统只认 Manifest 中 android:name=".ReminderReceiver" 这样的**字符串**，
# R8 不解析 Manifest 语义就会改名 → 组件无法实例化：上课提醒播不进来、
# 开机不重排闹钟、桌面小组件不刷新、VPN 前台服务起不来，而且全是**静默失效**，
# 不产生崩溃日志，只能靠功能回归发现。
# 逐条对应 android/app/src/main/AndroidManifest.xml：
#     activity  .MainActivity
#     service   .CampusVpnService
#     receiver  .AppWidget          （AppWidgetProvider，同时是广播接收器）
#     receiver  .ReminderReceiver
#     receiver  .BootReceiver
#     receiver  .PinWidgetReceiver
#     provider  androidx.core.content.FileProvider（由下面通用规则覆盖）
#
# 说明：AGP 通常会自动为 Manifest 声明的组件追加 keep 规则；这里显式写出是为了
# 让「为什么不能改名」在规则文件里可自查，不依赖 AGP 版本的隐式行为。
-keep class com.one.huaji.MainActivity { *; }
-keep class com.one.huaji.CampusVpnService { *; }
-keep class com.one.huaji.AppWidget { *; }
-keep class com.one.huaji.ReminderReceiver { *; }
-keep class com.one.huaji.BootReceiver { *; }
-keep class com.one.huaji.PinWidgetReceiver { *; }

# 通用兜底：凡继承系统组件基类的类都保留类名（新增组件时不会漏）。
-keep public class * extends android.app.Service
-keep public class * extends android.content.BroadcastReceiver
-keep public class * extends android.app.Activity
-keep public class * extends android.app.Application
-keep public class * extends android.appwidget.AppWidgetProvider
-keep public class * extends android.content.ContentProvider


# ---------------------------------------------------------------------------
# 8. androidx / kotlin：只做必要保留，**故意不整包 -keep**
# ---------------------------------------------------------------------------
# 理由：androidx 各库与 Kotlin 生态普遍自带 consumer rules（例如 androidx.core
# 的 FileProvider、flutter_secure_storage 的 Tink/crypto、WorkManager 的 Worker
# 反射实例化等），构建时会自动并入；再写 `-keep class androidx.**` 只会白白撑大
# APK 并挡住 R8 的优化，属于典型的过度保留。
#
# 真正需要在这里补、且默认规则**没有**提供的只有下面三项：
#
# (1) 行号与源文件名：默认 optimize 规则不含 SourceFile/LineNumberTable，
#     加上它才能把 release 崩溃栈映射回具体代码行（体积代价很小）。
-keepattributes SourceFile, LineNumberTable
-renamesourcefileattribute SourceFile
# (2) Kotlin 元数据：反射读 KClass、suspend 函数签名、data class 组件依赖它。
-keep class kotlin.Metadata { *; }
# (3) 单例 object / companion 的 INSTANCE 字段可能被反射访问。
-keepclassmembers class **$Companion {
    public static ** INSTANCE;
}


# ---------------------------------------------------------------------------
# 9. Flutter 可选的 Play Core（延迟组件 / Deferred Components）
# ---------------------------------------------------------------------------
# 首次开启 R8 后 release 构建会**直接失败**（实测）：
#     ERROR: R8: Missing class
#     com.google.android.play.core.splitcompat.SplitCompatApplication
#     (referenced from: void io.flutter.embedding.android
#      .FlutterPlayStoreSplitApplication.<init>() and 2 other contexts)
# 缺失的类一共 11 个，全部属于 com.google.android.play.core.**
# （splitcompat.SplitCompatApplication；splitinstall 的 SplitInstallException /
# SplitInstallManager / SplitInstallManagerFactory / SplitInstallRequest($Builder) /
# SplitInstallSessionState / SplitInstallStateUpdatedListener；tasks 的 Task /
# OnSuccessListener / OnFailureListener），来源是 Flutter 引擎里
# io.flutter.embedding.engine.deferredcomponents.PlayStoreDeferredComponentManager
# 对 Play Core 的**可选**依赖，不是本项目的代码。
#
# 本项目不使用延迟组件：pubspec 没有 androidDeferredComponents 配置，合并后的
# Manifest 里 application 解析为 android:name="android.app.Application"
# （不是 FlutterPlayStoreSplitApplication），因此这条路径在运行时永远不会被走到。
#
# AGP 已把逐类规则写进
# build/app/outputs/mapping/release/missing_rules.txt；下面用等价的包级通配覆盖
# 同一批类。注意**不要**改成 -ignorewarnings 或 -dontwarn ** —— 那会把真正的
# 混淆/缺类问题一起放行，正是本次接线要避免的事。
-dontwarn com.google.android.play.core.**
