# GitHub 源码发布区

公开源码仍以仓库根目录为准，不能把整个工程复制一份再维护。发布前在根目录检查 `git status`，只提交源代码、资源、测试和必要文档；本地 `HANDOFF.md`、`PROGRESS.md`、`release/internal/` 与构建产物会被忽略。

推荐流程：

1. 在根目录运行 `git diff` 和 `git status --short`，确认没有账号、密码、Cookie、Ticket、日志或内部测试文件。
2. 提交源码后推送到 [One-HuaJi/jizhicha](https://github.com/One-HuaJi/jizhicha)。1.0.3 使用提交说明 `release: 1.0.3`，并创建标签 `v1.0.3`；内测版本不创建正式标签。
3. 在 GitHub Release 上传 `release/official/v1.0.3/` 中的正式附件，并在 Release 说明里附上 SHA-256；`official/v1.0.2/` 保持不变。

正式 Android 构建前，必须先在本机创建 `jizhicha/android/key.properties`，并确保它引用独立 release keystore。该文件不会进入 GitHub。

三架构 `libhuse_vpn_mobile_ffi.so` 也是本机构建产物，不提交到源码仓库。Gradle 会从 Rust 源码自动生成并同步它们；新机器先安装对应三个 Rust Android target，再执行 Flutter 构建。

这个目录只保存发布规则，避免为公开仓库维护第二份容易过期的源码副本。
