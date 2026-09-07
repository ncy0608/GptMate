# GptMate

<img src="Resources/GptMateIcon.png" width="128" alt="GptMate icon">

一个轻量的 macOS 菜单栏和 Windows 11 系统托盘工具，用于查看 Codex 剩余额度、运行任务和任务结束提醒。

这是个人开发的非官方项目，与 OpenAI 无隶属关系。

## 功能

- 菜单栏显示运行任务数量与额度圆环。
- 根据剩余额度切换颜色：大于 30% 为绿色 `#28CD41`，大于 10% 且不超过 30% 为黄色 `#FFCC00`，不超过 10% 为红色 `#FF3B30`。
- 额度为 0% 时显示细红环，面板中的剩余百分比标红。
- 面板展示额度周期、剩余比例、重置时间，以及最多 5 个运行任务和可用的步骤摘要。
- 约每 8 秒刷新，并处理额度、任务等状态通知。
- 连接进程退出后尝试重连，支持手动刷新、重连和退出。
- 在任务退出运行列表时发送系统通知；需要用户允许通知。

## macOS 版

### 系统要求

- macOS 13 或更新版本。
- 本机安装并登录可用的 Codex 环境。应用通过本机 `codex app-server --stdio` 获取数据。
- 编译需要提供 Swift 编译器与 macOS SDK 的 Xcode Command Line Tools。

应用会检查 ChatGPT/Codex 应用包内的 CLI，以及 Homebrew、`~/.local/bin`、`~/.cargo/bin` 等常见安装位置。

### 从源码构建

在仓库根目录执行：

```bash
bash scripts/build.sh
```

分别生成两个单架构应用：Intel Mac 使用 `dist/x86_64/GptMate.app`；Apple Silicon（M 系列）Mac 使用 `dist/arm64/GptMate.app`。在“关于本机”中查看芯片或处理器类型，选择对应版本复制到自己的 Applications 文件夹后打开即可。

创建分发压缩包及 SHA-256 校验文件：

```bash
bash scripts/package.sh
```

发布时提供 `GptMate-v0.2.1-macOS-Intel-x86_64.zip` 和 `GptMate-v0.2.1-macOS-AppleSilicon-arm64.zip` 两个下载包，分别对应 Intel 和 M 系列芯片。每个压缩包附带独立的 `.sha256` 校验文件。

构建产物使用本地 ad-hoc 签名，尚未完成 Apple Developer ID 签名和公证。下载的应用可能受到 macOS 安全验证限制；有疑虑时可检查源码并自行构建。本项目不提供关闭系统安全检查的脚本。

## Windows 11 版

Windows 版位于 `Windows/`，使用 C#、.NET 8 和 Windows Forms，不依赖第三方 UI 组件。

- 支持 64 位 Windows 11，分别提供 x64 和 ARM64 版本。
- 点击系统托盘额度圆环打开状态窗口；右键可刷新、重连或退出。
- 自动寻找 `%APPDATA%\\npm\\codex.cmd`、常见 Codex/ChatGPT 安装目录及 `PATH` 中的 Codex CLI。
- 发布包为自包含单文件程序，无需预装 .NET 运行时。

在 Windows 11 中安装 .NET 8 SDK 后，从仓库根目录运行：

```powershell
./Windows/package.ps1
```

生成 `GptMate-v0.3.0-Windows-x64.zip` 和 `GptMate-v0.3.0-Windows-ARM64.zip`，以及对应的 SHA-256 校验文件。GitHub Actions 也会在 Windows 环境自动构建这四个文件。

首次 Windows 预览包尚未进行 Microsoft 代码签名，SmartScreen 可能显示未知发布者。源码与自动构建流程均已公开，可核对校验值或自行构建。

## 使用与隐私

启动后点击菜单栏圆环或任务文字查看面板。额度取自 Codex 返回的数据，圆环使用主额度窗口，面板同时展示可用的次级额度窗口。

应用会读取 Codex 返回的本地会话日志路径，以辅助识别任务运行状态与当前活动。任务标题和可用的活动摘要可能显示在面板中，任务结束通知可能包含任务标题；请在分享截图时留意这些内容。

当前应用代码没有额外的分析上报或自建遥测服务。Codex CLI 自身的网络行为由其配置和服务决定。源码仓库与分发包不包含账号配置、Token、真实会话日志或启动台数据库。

仓库版由用户手动启动和退出，不会安装后台守护脚本。作者本机的自动启动配置不属于分发内容。

## 已知限制

- 任务识别目前仅检查最近 20 个任务；面板最多展示 5 个。
- “任务完成”通知按任务退出运行列表判断，暂时不能区分成功、失败或中止。
- 接口或本地会话日志格式变化可能影响兼容性。
- 暂未提供数据过期提示、低额度通知、多账号管理与自动更新。
- 未发现额度数据时显示等待状态；失败后的旧数据尚无独立过期标识。

## 项目结构

```text
Sources/       macOS SwiftUI/AppKit 界面、状态模型、CLI 通信和日志检查
Resources/     Info.plist 与应用图标
scripts/       Intel / M 系列独立构建与打包脚本
Windows/       Windows Forms 托盘程序、资源和双架构打包脚本
docs/          图标设计说明与预览版发布说明
```

应用图标由内置 imagegen 生成，设计提示词见 `docs/icon-design.txt`。

## 许可证

本项目采用 [MIT 许可证](LICENSE)，允许商业使用、修改和再分发，须保留版权声明与许可证。软件按现状提供，不附带担保。完整条款以 LICENSE 文件为准。
