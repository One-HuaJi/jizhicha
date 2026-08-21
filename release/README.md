# 稽之查发布区

这里把源码发布、GitHub Release 附件和内部测试包分开管理，避免把交接文档或测试文件误提交到公开仓库。

## 目录约定

- `official/v1.0.2/`、`official/v1.0.3/`：按版本永久保留、准备上传到 [GitHub Releases](https://github.com/One-HuaJi/jizhicha) 的正式附件。正式 APK/Windows ZIP 不建议直接提交到源码仓库；上传 Release 时同时发布 SHA-256 和版本说明。
- `internal/`：内部测试包、临时截图和测试日志。该目录默认被 Git 忽略，仅供团队成员本机交换。
- `source/`：GitHub 源码发布规则。GitHub 源码发布使用仓库根目录中经过检查的工程文件；`HANDOFF.md`、`PROGRESS.md` 等交接材料只放在本地，不应作为源码提交内容。

## 当前版本

正式构建版本：`1.0.3+10300`。其中 `1.0.3` 是用户看到的版本，`10300` 只是 Android 用来保证升级顺序的内部 build number。

Android 正式 Release 必须读取 `jizhicha/android/key.properties` 中的独立 release keystore；该文件和 keystore 均被 Git 忽略。没有 keystore 时，正式构建会主动失败；只有显式设置 `ALLOW_DEBUG_SIGNING=true` 才允许生成内测用 Debug 签名包。

Windows 发布前请使用对应版本的 `Jizhicha-v<版本>-Windows.zip`，并检查其中包含 `jizhicha.exe`、`huse_vpn_ffi.dll`、`wintun.dll` 及 Flutter 运行库。

当前客户端只保留 Android、Windows、Linux 与 Web 工程；iOS 与 macOS 已永久移除，不应通过 `flutter create` 重新生成对应目录。Android 构建会由 Gradle 自动重编并同步三架构 Rust 原生库，禁止手工复用旧 `.so`。

## 内部小版本规则

内部测试版本使用预发布版本号，例如 `1.0.3-internal.001`、`1.0.3-internal.002`。每次新编译只保留 `release/internal/current/` 中的最新小版本，删除同一测试基线下的上一个小版本；`official/v1.0.2/`、`official/v1.0.3/` 等正式版本目录永远不删除。内部 build number 从正式版本号对应的 `10300` 之后递增，避免 Android 升级序号倒退。

## GitHub 提交流程

源码提交在仓库根目录执行：

```powershell
git status --short
git diff --check
git add -A
git diff --cached --name-only
git commit -m "release: 1.0.3"
git push origin main
git tag -a v1.0.3 -m "稽之查 1.0.3"
git push origin v1.0.3
```

`HANDOFF.md`、`PROGRESS.md`、`android/key.properties`、APK、ZIP 和校验文件已加入忽略规则。提交前仍必须检查 `git diff --cached --name-only`，确认没有账号、密码、Cookie、日志或本地测试文件。
