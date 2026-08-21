# 内部测试版

把内部测试 APK、Windows 测试压缩包和临时日志放在这里。该目录内容默认不进入公开 GitHub 源码提交。

已归档的 1.0.2 同步测试包位于 `release/internal/v1.0.2-debug/`，Android 使用 Debug 证书签名，不能作为正式版发布。

内部版本统一使用 `v1.0.3-internal.001`、`v1.0.3-internal.002` 这种预发布命名，产物放在 `release/internal/current/`。每次编译前删除该目录中的上一个内部版本，只保留最新一次；正式版本目录 `release/official/v1.0.2/`、`release/official/v1.0.3/` 等永远保留。需要对外发布时，重新构建正式签名包并复制到对应的 `official/v<版本>/` 目录，再上传 GitHub Release。
