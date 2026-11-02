# jizhicha/tool —— 发布前检查与脱敏构建

这两个脚本是"防止构建机本地路径进入公开产物"这条纪律的执行工具。

## 背景（为什么要脱敏构建）

Dart AOT 快照会把**构建时的工作目录绝对路径**编进产物：

| 产物 | 泄漏所在条目 |
|---|---|
| Android APK | `lib/<abi>/libapp.so` |
| Windows 发布包 | `data/app.so`、`gal_plugin.dll` |

真实形态（**掩码后**）：`D:/<工作区>/com.one.***/chengpin/jizhicha/.dart_tool/flutter_build/dart_plugin_registrant.dart`

**唯一可行的修法**：把仓库复制到一个**中性路径**（如 `C:\build\jizhicha-<ver>-sanitize\jizhicha`）再构建 ——
编进去的就变成中性路径。v1.0.2 / v1.0.3 用的就是这个做法，v1.0.4 起被丢弃，于是每版必带。
修复源码里的路径字符串**没有用**：路径是构建环境决定的，不是源码写死的。

## 用法

```powershell
cd <仓库>\chengpin\jizhicha

# 发布构建（推荐入口）：复制到中性目录 → flutter build → 自动跑断言门
.\tool\build_release_sanitized.ps1 -Version 1.1.0+13000

# 单独检查任意产物（APK / Windows zip / 目录）
.\tool\check_release_artifacts.ps1 -Path .\build\app\outputs\flutter-apk\app-release.apk
.\tool\check_release_artifacts.ps1 -Path ..\release\official\v1.0.3
```

`check_release_artifacts.ps1` 退出码：`0` 全部通过 / `1` 有命中或无法扫描 / `2` 用法或路径错误。
`-MaxHits <n>`（默认 20）只限制**明细**条数，总数与"按规则计数"始终完整 —— 内部产物里
同一形态可能出现几百次（实测 `release\internal\v1.0.2-debug` 的 Windows 包在 `huse_vpn_ffi.dll`
里有 538 处 `windows-user`），全量打印只会把 CI 日志冲爆。

> 扫描范围里 **Windows 发布 zip 有三种打包形态**，脚本都会认（早期版本只认第一种，
> 导致后两种被误判成 Android APK 且"扫描条目数 0"，即**静默漏检**）：
> `data/app.so`（v1.0.2/1.0.3）｜ `Jizhicha-vX-Windows/data/app.so`（v1.0.4–v1.0.7）｜
> `data\app.so`（反斜杠，v1.0.8/1.0.9）。

### 门报了失败怎么处理

1. 看 `规则=` 与 `条目=`：`workspace-root` / `workspace-dir` 命中在 `libapp.so`、`data/app.so`
   ⇒ 就是本文开头那个缺陷，**换中性目录重新构建**（用 `build_release_sanitized.ps1`）。
2. 命中在 `gal_plugin.dll` / `huse_vpn_ffi.dll` ⇒ 同样是构建目录被写进了原生库
   （`.plugin_symlinks` / cargo 的编译期路径），**同样只能靠换中性目录重编**。
3. 若产物是 **debug / 内部** 包：这类包本来就带完整调试路径，**不能作为公开发布物**。
   实测 `release\internal\v1.0.2-debug\Jizhicha-v1.0.2-Windows.zip` 在 `huse_vpn_ffi.dll` 里
   有 538 处 `windows-user` 命中，而同版本 `release\official\v1.0.2\...Windows.zip` 是 0 处。

### build_release_sanitized.ps1 参数

| 参数 | 说明 |
|---|---|
| `-Version` | 版本号，用于拼接脱敏目录名；省略则从 `pubspec.yaml` 读 |
| `-SanitizeRoot` | 脱敏工作区根，默认 `C:\build` |
| `-OutDir` | 门通过后把 APK 复制到该目录 |
| `-Force` | 工作区有未提交改动时继续（默认拒绝） |
| `-SkipBuild` / `-NoCopy` | 仅用于流程验证，日常发布不要用 |

## 断言门在查什么

命中下列形态即失败，并把**条目名 + 规则 + 偏移**打印出来（**命中原文一律掩码**）：

| 规则 | 形态 | 含义 |
|---|---|---|
| `workspace-root` | `AAAAAihaveideas` | 本机工作区盘根目录名 |
| `workspace-dir` | `com.one.` 开头的整段 token | 工作区上层目录名（见下方白名单） |
| `windows-user` | `C:\Users\` | Windows 真实构建账户目录 |
| `macos-user` | `/Users/` | macOS 用户目录 |
| `linux-user` | `/home/` | Linux 用户目录 |

命中明细每行都会打印 `规则=` / **`命中字面=`（该规则的正则本身，用来证明"到底命中了哪种形态"）** /
`条目=` / `偏移=` / `掩码形态=`。之所以要这一列：通用掩码会把 `C:\Users\<账户>` 与
`C:\<随便什么目录>\...` 都压成 `C:\***`，只看"掩码形态"无法判断命中的是账户目录还是别的路径。

### 白名单（应用自有标识，不算泄露）

`classes.dex` 与 `libapp.so` 里必然出现应用自己的命名空间，这些**不是**隐私泄漏：

```
com.one.huaji
com.one.huaji.ACTION_CLASS_REMINDER
com.one.huaji.ACTION_PIN_WIDGET_RESULT
com.one.huaji.action.CONNECT
com.one.huaji.action.DISCONNECT
```

⚠️ **维护提醒**：若 Android 侧新增 `com.one.huaji.<TOKEN>` 形态的字面串，
必须把该 token 补进 `check_release_artifacts.ps1` 的 `$AllowedSelfIdentifiers`，
否则断言门会把正确产物误判为命中。

> 这条白名单是必须的：Gate 最初按"命中 `com.one.` 一律失败"实现，结果**已知好产物
> `Jizhicha-v1.0.3-arm64.apk` 也失败**（它在 `classes.dex` 里含 3 处自有 action/MethodChannel 名）。
> 规则因此收紧为"整段 token 精确白名单豁免 + 其余 `com.one.<其他>` 仍算命中"。

## 脱敏目录里被排除的东西

`.git`、`build`、`.dart_tool`、`release`、`HANDOFF.md`、`docs\internal`、`.idea`、
`android\app\release`、`huse-vpn-next\target`（~19 GB cargo 中间产物）、
`windows\flutter\ephemeral`、`linux\flutter\ephemeral`、`android\.gradle`、`android\build`、
`*.jks` / `*.keystore` / `*.p12` / `*.pfx` / `key.properties` / `*.apk` / `*.zip` / `*.aab` / `*.iml`

签名密钥**不进**脱敏目录：`JIZHICHA_KEYSTORE_FILE` 用环境变量指向仓外的原路径即可。
脚本还会在复制后**再校验一次**脱敏目录里没有任何密钥文件，发现即中止。

## 已知边界（脚本不做的事）

- **不修复**：只检查。修复只能靠"换中性目录重新构建"。
- **不碰 git**：不做 `commit` / `add` / `stash` / `checkout`；只读 `git status` 用于告警。
- **不覆盖 `libflutter.so` / `flutter_windows.dll`**：这两个是官方预编译产物，内嵌路径来自
  Google / Flutter 的构建机，与本机工作区无关，纳入判定只会制造噪声。
- `-SkipBuild` / `-NoCopy` 分支没有跑过完整构建（见交接文档记录），日常发布走默认路径。

## 隐私自查（这两个脚本自身）

脚本会被公开，所以脚本自己的输出与源码同样受隐私纪律约束：

- **构建账户名**（真实账户目录）在脚本里**只以掩码形态出现**：`C:\Users\***`。
  源码与输出中都没有该账户名。本目录下 `huaji` 这个子串全部来自**应用自己的包名**
  `com.one.huaji`（白名单项），不是账户名。
- 工作区盘根目录名 `AAAAAihaveideas` 在源码里只出现 3 处：gate 的规则定义与它的掩码函数、
  以及 `build_release_sanitized.ps1` 里 `$env:PUB_CACHE` 的**必需取值**（该目录不在 C 盘，
  是实际依赖路径；它是目录名不是账户名）。gate 的输出里**从不**出现这个原始 token ——
  命中一律显示为 `<workspace-root>`；实测 gate 输出中该 token 出现 0 次。
- `build_release_sanitized.ps1` 的所有日志行都过 `Get-SafePathLabel`，仓库路径显示为
  `D:\<workspace-root>\com.one.\***\chengpin\jizhicha`、账户目录显示为 `C:\Users\***`。
