# GptMate v0.3.0 Windows 预览版

新增原生 Windows 11 系统托盘版本。

- 提供 Windows x64 和 Windows ARM64 两个独立便携包。
- 托盘圆环显示 Codex 主额度，颜色阈值与 macOS 版一致。
- 状态窗口展示额度、重置时间、运行任务与步骤摘要。
- 每 8 秒刷新，支持手动刷新、重连及任务结束气泡提醒。
- 通过本机 `codex app-server --stdio` 读取数据，不包含账号、Token 或真实会话日志。

Windows 版需要 64 位 Windows 11，不要求预装 .NET 运行时，但需要本机已安装并登录可用的 Codex CLI。

这是首次 Windows 预览构建，需在 Windows 11 实机验证不同 Codex 安装方式。安装包尚未进行 Microsoft 代码签名，Windows SmartScreen 可能显示未知发布者。
