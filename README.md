# 稽之查（jizhicha）

> 湖南科技学院校园助手 —— 面向 Windows 与 Android 的 Flutter 应用，内置 Rust 校园内网加速器。

当前只支持 Windows 与 Android；iOS 和 macOS 当前及以后均无支持计划，相关工程已从源码删除。

## 功能

- **校园加速器**：内嵌 Rust VPN 核心，通过 Dart FFI 直连学校网关，无需安装第三方 VPN 客户端。离开校园内网环境也能访问教务、图书馆、知网等服务
- **一键教务查询**：通过已验证的加速器隧道请求教务系统，自动更新最新学期成绩并复用历史缓存；发现数据异常时可手动刷新全部成绩
- **智慧课表**：周视图高亮 + 按周筛选，支持深色模式
- **体测计算器**：输入各项实测数据，自动换算等级与总分
- **隐私安全**：账号密码使用系统安全存储加密（Windows DPAPI / Android Keystore），网关 TLS 使用 SPKI Pinning，账号数据不上传第三方云端

## 后续计划

- 继续优化课表样式和个性化布局
- 根据校园实际使用反馈完善兼容性

## 技术栈

| 层级 | 技术 |
|------|------|
| UI 框架 | Flutter 3.x（Dart） |
| VPN 核心 | Rust（Wintun / Android VpnService） |
| FFI 桥接 | `dart:ffi` + Flutter FFI Plugin |
| 网络请求 | Dio + Cookie Jar |
| 本地存储 | `flutter_secure_storage` + 本地 JSON / HTML 缓存 |

## 构建

### Windows

```powershell
$env:PUB_CACHE = '<your-flutter-pub-cache>'
flutter build windows --release
# 产物：build\windows\x64\runner\Release\jizhicha.exe
```

### Android

```powershell
$env:PUB_CACHE = '<your-flutter-pub-cache>'
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
flutter build apk --release --split-per-abi
# 产物：build\app\outputs\flutter-apk\app-<arch>-release.apk
```

Gradle 会使用 Flutter 配置的 Android NDK，自动为 ARMv7、ARM64、x86_64 增量重编 Rust 原生库，避免复用旧 `.so`；生成的 `jniLibs` 不进入 Git。正式构建还必须在本机配置不进入 Git 的 `android/key.properties` 与独立 release keystore。

> 最低支持 Android 8.0（API 26）

## 下载

前往 [Releases](https://github.com/One-HuaJi/jizhicha/releases) 获取预编译安装包：

- `Jizhicha-vX.X.X-Windows.zip` — 解压即用
- `Jizhicha-vX.X.X-arm64.apk` — 主流 Android 手机
- `Jizhicha-vX.X.X-armeabi-v7a.apk` — 老旧 Android 设备
- `Jizhicha-vX.X.X-x86_64.apk` — 模拟器

## 反馈

- 邮件：[1410983@qq.com](mailto:1410983@qq.com)
- GitHub Issues：[提交 Issue](https://github.com/One-HuaJi/jizhicha/issues)

## 开源协议

MIT License © 2026 One-HuaJi
