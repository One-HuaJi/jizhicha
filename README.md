# 稽之查（jizhicha）

> 湖南科技学院校园助手 ——  跨平台桌面 / 移动端应用，内置 Rust 校园内网加速器。

## 功能

- **校园加速器**：内嵌 Rust VPN 核心，通过 Dart FFI 直连学校网关，无需安装第三方 VPN 客户端。离开校园内网环境也能访问教务、图书馆、知网等服务
- **一键教务查询**：通过加速器隧道直接请求教务系统，登录一次即可抓取全部学期课表和成绩，离线查看
- **智慧课表**：周视图高亮 + 按周筛选，支持深色模式
- **体测计算器**：输入各项实测数据，自动换算等级与总分
- **隐私安全**：账号密码使用系统安全存储加密（Windows DPAPI / Android Keystore），不联网不传云端

## 未来功能
搓个更换密码
搓个课表美化
暂时就这么多

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
flutter build apk --release --split-per-abi
# 产物：build\app\outputs\flutter-apk\app-<arch>-release.apk
```

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
