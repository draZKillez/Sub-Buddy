# AI看剧伴侣 / AI Viewing Companion

一款仍在认真打磨中的 macOS 本地字幕工具：主要用途帮助你生成一份字幕，支持十种语言。从 MKV 提取文字字幕、在本机识别图片字幕或英语音轨，再以手动、Apple 本地翻译或 Codex 三种方式生成目标语言 SRT。

macOS 当前版本为 **0.7.1**，最低支持 macOS 14，安装包为 Universal 2，可运行于 Apple Silicon 和 Intel Mac。仓库也保留一个以手动字幕工作流为核心的 iOS/LiveContainer 0.4.0 测试版。

> [!IMPORTANT]
> 这是一个由真实需求和实际看片测试推动、借助 Codex 协作完成的 **vibe coding 个人项目**。需求取舍、测试素材和最终判断来自维护者，Codex 参与了代码实现、重构、测试和排错。它不是成熟商业产品，也不应被理解为“AI 写完便无需审查”：项目仍可能有遗漏和兼容性问题，欢迎提交可复现的 Issue。请先用副本或可重新取得的媒体测试。

## 下载与要求

测试版本会发布在 [GitHub Releases](https://github.com/draZKillez/AI-Viewing-Companion/releases)。macOS 版最低要求 macOS 14；Apple 本地翻译需要 macOS 15 或更高版本。当前测试 DMG 使用 ad-hoc 签名，尚未进行 Apple Developer ID 公证，第一次打开时可能需要在“系统设置 → 隐私与安全性”中确认。

## 为什么做这个项目

很多 MKV 已经带有英文字幕，却缺少合适的目标语言字幕；也有文件只有 PGS/VobSub 图片字幕，甚至完全没有字幕。手工提取、分段翻译、检查序号和时间轴、再整理输出并不复杂，但步骤零散且容易漏条目。

AI看剧伴侣尝试把这些步骤放进一个简单的原生界面，同时坚持几条边界：

- 默认生成独立 SRT，不修改原始 MKV。
- 能在本机完成的提取、OCR、语音识别和系统翻译尽量留在本机。
- 使用在线 Codex 时明确告诉用户发送了什么，不接触登录凭据。
- 外部进程全部使用可执行文件和参数数组启动，不拼接 shell 命令。
- 对字幕 ID、数量、时间轴和模型输出做程序校验，而不是盲目信任 AI。

## 核心功能

### 字幕与媒体处理

- 读取 MKV 容器标题、音轨和全部字幕轨道，显示编号、编码、语言、名称、默认、强制和 SDH 信息。
- 支持 SRT/SubRip、ASS/SSA 和常用 WebVTT 文字字幕。
- PGS 与 VobSub/DVD 图片字幕可通过 Apple Vision 在本机 OCR；原始图片不会上传。
- 内嵌精简的 FFmpeg 8.1.2 与 ffprobe，macOS 版本同时支持 arm64 和 x86_64。
- 检测到本机 `mkvextract` 时优先快速分离字幕；没有也可使用内嵌 FFmpeg。
- 默认输出与视频同目录的独立 SRT；也保留用户主动选择后无损新增字幕轨道的 MKV 封装功能。
- 视频和音频不重新编码，原始 MKV 永不直接覆盖。

### 本地英语语音识别

- 从用户选择的英语音轨提取 16 kHz 单声道音频，通过内嵌 whisper.cpp 在本机生成 `.en.srt`。
- Base、Small、Medium、Large v3 Turbo 四种模型按需下载，不把大型模型塞进 DMG；默认选择 Small。
- 下载完成后校验模型文件，支持进度、取消和删除。
- Base 适合快速预览；Small 平衡速度与准确率；Medium 更稳但更慢；Large v3 Turbo 更适合较新的 Apple Silicon Mac。

### 三种翻译方式

1. **手动分段翻译**：无需登录。应用默认按 500 条拆分，生成可复制提示；用户把外部 AI 返回的完整 SRT 粘贴回来，应用校验、保存并最终合并。
2. **Apple 本地翻译**：macOS 15+ 可用。语言包经用户同意后由系统下载，字幕正文留在设备上；系统不支持的语言组合会明确提示。
3. **Codex 自动翻译**：使用用户自己的官方 ChatGPT/Codex 登录，不要求 API Key。按块提交正文和上下文，解析严格 JSON，并对缺失或重复 ID 自动修复一次。

源语言和目标语言目前均提供英语、简体中文、西班牙语、法语、德语、日语、韩语、葡萄牙语、俄语和阿拉伯语。App 界面语言也可独立选择这十种语言，不会改变字幕设置。

### 长任务与输出

- 自动翻译和手动翻译默认每份 500 条，可在 1–1000 条范围内调整。
- 保存已完成分块；语言、轨道、片名上下文或翻译提供者改变时不会混用旧进度。
- 显示当前阶段、字幕范围、完成和剩余数量、累计用时、预计剩余范围及预计完成时间。
- 支持取消、失败重试、仅译文/双语 SRT，以及 macOS 文件夹递归队列。
- 简体中文仅译文默认与视频同名，例如 `Movie.mkv` 输出 `Movie.srt`；其他语言和双语文件带语言后缀，避免互相覆盖。

## Codex 的工作原理与隐私边界

Codex 模式不是调用隐藏网页接口，也不是读取 ChatGPT Cookie。应用只负责启动用户机器上已经安装的官方 `codex` 可执行文件。

### 登录

点击“连接 ChatGPT”后，应用以参数数组运行：

```text
codex login
```

浏览器登录、凭据保存和登录状态均由 Codex CLI 自己管理。应用只运行 `codex login status` 判断是否已登录，并且：

- 不读取、复制、解析或上传 `auth.json`。
- 不读取浏览器 Cookie。
- 不要求用户填写 OpenAI API Key。
- 不在界面或日志中显示访问令牌。

### 每个翻译块如何调用

当前实现使用类似下面的非交互调用，实际参数以数组直接交给 Swift `Process`：

```text
codex exec --ephemeral --json --sandbox read-only \
  --skip-git-repo-check --ignore-user-config --ignore-rules \
  -c model_reasoning_effort="none" \
  -C <每次新建的空临时目录> \
  -m <用户明确选择的模型> -
```

提示内容通过 **stdin** 输入，不放进超长命令参数；返回的 JSONL 只取最终 `agent_message`，再由应用验证 ID、数量、空正文和额外字段。临时工作目录为空，任务结束后删除，并使用只读 sandbox；提示也明确要求模型不要调用工具或读取本地文件。

### 会发送给 Codex 的内容

选择 Codex 自动翻译即代表这些文字会经 Codex CLI 发送到 OpenAI 服务处理：

- 当前核心字幕块的正文和字幕 ID。
- 前后约 50 条字幕正文，仅作为理解上下文，不要求重复输出。
- 用户界面中的原始片名、目标语言片名和年份。
- 当前跨块术语表；格式修复时还可能包含上一次不合格的模型输出。

不会作为翻译提示发送的内容包括：MKV 视频、音频、字幕图片、完整文件路径、Codex 登录凭据和浏览器数据。片名可能由文件名推测，所以推测后的片名文字本身会成为上下文。

自动翻译完成进度、译文和术语表会保存在用户 Mac 的 Application Support 中，以便失败或取消后续传；应用目前没有自行实现遥测、广告 SDK 或用户行为分析。Codex 服务本身的网络处理和数据政策仍由用户所使用的 ChatGPT/Codex 服务条款决定。

### 明确不做的自动行为

- 模型不可用、未登录、额度用尽或服务失败时直接报错。
- 不会暗中切换到 OpenAI API、其他模型或第三方翻译服务。
- 用户选择 Apple 本地翻译或手动模式时，不会为了“提高质量”偷偷调用 Codex。

## 本地处理与网络请求概览

| 功能 | 是否离开设备 | 说明 |
| --- | --- | --- |
| FFmpeg/ffprobe 提取 | 否 | 内嵌版本关闭网络协议，处理本地媒体文件 |
| Apple Vision OCR | 否 | PGS/VobSub 图片在本机识别 |
| Whisper 识别 | 识别时否 | 模型首次下载需要网络，之后推理在本机 |
| Apple Translation | 否 | 首次下载系统语言包需要网络和用户许可 |
| 手动分段模式 | 由用户决定 | App 只复制和校验；用户自行选择把文本粘贴到哪里 |
| Codex 自动翻译 | 是 | 仅发送上文列出的字幕文字和电影上下文 |
| Sparkle 更新 | 是 | 从本项目 GitHub Releases 检查和下载签名更新 |

## 构建与测试

需要 Xcode 16 或兼容的 Swift 5.10+ 工具链：

```sh
zsh scripts/setup_dependencies.sh
swift run MKVSubtitleTranslator
swift test --disable-sandbox
```

构建 FFmpeg 与 Universal 2 DMG：

```sh
zsh scripts/build_ffmpeg_macos.sh
zsh scripts/package_dmg.sh
```

iOS/LiveContainer 测试包：

```sh
zsh scripts/build_ffmpeg_ios.sh
zsh scripts/package_ipa.sh
```

依赖准备脚本会校验 Whisper 1.9.2、Sparkle 2.9.6 和 FFmpeg 8.1.2 固定归档。展开后的框架、构建缓存、模型和输出安装包不会提交到 Git。Sparkle + GitHub Releases 自动更新的维护方法见 [UPDATE_SETUP.md](UPDATE_SETUP.md)。

## 工程结构

- `Sources/MKVSubtitleCore/`：容器检查、字幕解析/写入、OCR、Whisper、翻译、进度和外部进程服务。
- `Sources/MKVSubtitleTranslatorApp/`：macOS SwiftUI 界面、Apple Translation 与 ViewModel。
- `iOS/Sources/`：iOS 手动字幕工作流和原生 FFmpeg 桥接。
- `Tests/MKVSubtitleCoreTests/`：字幕时间轴、分块、Codex JSONL、输出验证、进程参数和持久化测试。
- `scripts/`：依赖准备、FFmpeg 构建、DMG/IPA 打包和 GitHub Release 发布。
- `Vendor/`：固定依赖归档、许可证、可复现构建资料与必要的 C 桥源码。

## 已知限制

- 这是测试阶段的个人项目，请勿把它当作唯一字幕备份或无人值守的生产工具。
- DVB 与 XSUB 图片字幕尚不支持 OCR；PGS 与 VobSub/DVD 已支持。
- 图片字幕 OCR 无法还原原字体、颜色和精确屏幕位置；低对比度、花体和混合语言需要人工校对。
- Whisper 会受背景音乐、多人重叠对白、口音和所选模型影响。
- Apple Translation 偏向逐条系统翻译，不接收电影片名和跨块术语表；重视上下文一致性时可选择手动或 Codex 模式。
- WebVTT 的复杂 REGION/STYLE/NOTE 尚未完整保真；旧字幕编码可能需要先转换为 UTF-8。
- 测试 DMG 使用 ad-hoc 签名；在取得 Developer ID 并完成公证前，首次安装可能出现 Gatekeeper 提示。
- iOS 版目前仍以单文件手动翻译为核心，不包含 Codex 自动翻译、文件夹队列或 MKV 重新封装。
- 项目根许可证尚待维护者确认；FFmpeg、Whisper、Sparkle 等第三方组件分别遵循其自身许可证，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 反馈

如果它恰好解决了你的问题，我会很高兴；如果没有，也欢迎通过 Issue 提供：macOS/芯片型号、字幕编码、可公开的最小复现文件或日志、预期结果和实际结果。请先移除片名、路径或字幕中不愿公开的内容，也不要上传任何 Codex 登录文件或令牌。

这个项目仍在学习和修正中。准确描述问题，比一句“不能用”更能帮助它变得稳定。
