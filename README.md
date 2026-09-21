# 稽之查（jizhicha）

> 湖南科技学院校园助手 —— 面向 Windows 与 Android 的 Flutter 应用，内置 Rust 校园内网加速器。

当前只支持 Windows 与 Android；iOS 和 macOS 当前及以后均无支持计划，若确实有需求请自己维护

- 本项目维护至2028年下半年
- 学校校园内网免费 100mbps校园宽带付费 请知悉 登教务系统无需多付费 *警惕诈骗*


## 功能

- **校园加速器**：内嵌 Rust VPN 核心，通过 Dart FFI 直连学校网关，无需安装第三方 VPN 客户端。离开校园内网环境也能访问教务、图书馆、知网等服务
- **一键教务查询**：通过已验证的加速器隧道请求教务系统，自动更新最新学期成绩并复用历史缓存；发现数据异常时可手动刷新全部成绩
- **智慧课表**：周视图高亮 + 按周筛选，支持深色模式,暂时还没那么智慧
- **体测计算器**：输入各项实测数据，自动换算等级与总分
- **隐私安全**：账号密码使用系统安全存储加密（Windows DPAPI / Android Keystore），网关 TLS 使用 SPKI Pinning，账号数据不上传第三方云端（项目已开源，可自行查看安全度）

## 后续计划
- 增加教务系统选课（调整接口会导致功能失效且无自检，请勿当做主办法使用，自行准备备选工具）
- 天下苦综评久矣 增加方便快捷的学期末一键综评（2027年见）

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
flutter build apk --release --target-platform android-arm64
# 产物：build\app\outputs\flutter-apk\app-release.apk（仅 arm64-v8a）
```

> 最低支持 Android 8.0（API 26）
>
> **发布版只提供 arm64 真机包**（不含 armeabi-v7a 与 x86_64 模拟器版本）。
> 其它 ABI 的原生库会在打包前被过滤，见 `android/app/build.gradle.kts` 末尾的
> `[abi-filter]` 段。
>
> 签名凭据通过 `JIZHICHA_KEYSTORE_FILE` / `JIZHICHA_KEY_ALIAS` /
> `JIZHICHA_STORE_PASSWORD` / `JIZHICHA_KEY_PASSWORD` 环境变量提供；
> `android/key.properties` 只保留非敏感的路径与别名。

## 下载

前往 [Releases](https://github.com/One-HuaJi/jizhicha/releases) 获取预编译安装包：

- `jizhicha-vX.X.X-arm64-v8a.apk` — Android 真机（当前唯一提供的 Android 包）

> v1.1.0 起不再发布 armeabi-v7a / x86_64 模拟器版本，也不再发布 Windows 包。
> 每个正式包都附带 `SHA1SUMS` / `SHA256SUMS`，安装前可自行校验。

## 反馈

- 邮件：[1410983@qq.com](mailto:1410983@qq.com)
- GitHub Issues：[提交 Issue](https://github.com/One-HuaJi/jizhicha/issues)

## 开源协议

MIT License © 2026 One-HuaJi
