# HUSE 桌面端源码副本

这是供前端重构使用的单一桌面端源码目录。VPN Rust 核心已经放入
`jizhicha/huse-vpn-next/`，由 Flutter 通过 FFI 集成；目标是最终只生成一个教务查询桌面程序，不拉起独立 VPN 窗口。

源码副本初始创建时没有带入构建产物；本轮按需求额外生成了一个测试版 Windows EXE。

## 目录

- `jizhicha/`：Flutter 教务查询桌面端源码。主要前端入口是 `lib/main.dart`，Windows 工程在 `windows/`。
- `jizhicha/huse-vpn-next/`：内嵌的 Rust 校园 VPN 核心、FFI 层、Tauri 旧桌面壳及 `vendor/wintun-bindings-0.6.4` 源码。

## 说明

- Flutter 桌面端通过 Dart FFI 集成 `jizhicha/huse-vpn-next/ffi`，不再依赖同级独立 VPN 项目或独立 VPN 窗口。
- 副本中的旧版独立 VPN 启动器/本地控制 API 已移除，`lib/main.dart` 保留内嵌 FFI 调用链。
- `jizhicha/windows/CMakeLists.txt` 已改为从 `../huse-vpn-next` 查找 Rust 源码构建产物；测试构建会把 FFI DLL 和 `wintun.dll` 放到 EXE 同目录。
- `jizhicha/lib/credential_store.dart` 使用 `flutter_secure_storage` 10.3.1；Windows 凭据由系统安全存储（DPAPI）保护，VPN 账号和教务账号分开保存，只有认证成功后才写入。
- 测试版输出在 `jizhicha/build/windows/x64/runner/Release/jizhicha.exe`，窗口标题为“稽之查”。
- `jizhicha/tools/` 只保留了依赖下载脚本，未复制 `gof5_windows_amd64.exe` 和 `wintun.dll`。
- Flutter/Rust 的源代码副本没有携带初始构建产物；本轮构建生成的 `build/`、Rust `target/` 和测试 EXE/DLL 仅属于当前测试环境。
- `chengpin` 同级的独立 `huse-vpn-next/` 副本已删除；原工作区的源码未改动，仅追加了本次交接记录。
