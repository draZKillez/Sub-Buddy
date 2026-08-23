# AI看剧伴侣 / AI Viewing Companion

AI看剧伴侣是 macOS 14+ 原生 SwiftUI 应用，可从 MKV 提取或 OCR 字幕、用本地 Whisper 从英语音轨生成 SRT，并自动或手动分段翻译。macOS 包为 Universal 2，兼容 Apple Silicon 与 Intel。

当前 macOS 版本为 0.6.0，iOS/LiveContainer 测试版为 0.3.2。

## 主要功能

- 源语言与目标语言均可选择：英语、简体中文、西班牙语、法语、德语、日语、韩语、葡萄牙语、俄语、阿拉伯语。
- App 界面语言可在右上角独立选择同样十种语言；它不会改变字幕原文或目标语言。
- 读取 MKV 容器信息和全部字幕轨道，优先选择与源语言匹配的轨道，也允许手动选择。
- 支持 SRT/SubRip、ASS/SSA、基础 WebVTT；PGS 使用 Apple Vision 完全在本机 OCR。
- 可选择英语音轨，用本地 whisper.cpp 生成独立 `.en.srt`；Base、Small、Medium、Large v3 Turbo 四种模型由用户按需下载，默认 Small。
- 自动模式通过用户自己的官方 Codex 登录，支持 Luna、Terra、Sol，不读取令牌、不使用 API Key、不自动切换模型。
- 手动模式无需 Codex：按 1–1000 条拆分，默认 500；复制完整提示，逐份粘贴、校验、保存和合并。
- 输出“仅译文”或“双语（译文 + 原文）”SRT；默认不修改、不覆盖、也不重新封装原 MKV。
- 保存自动块级进度和手动分段进度；语言、轨道或分块设置改变时不会误用旧进度。
- 显示当前阶段、字幕范围、完成/剩余数量、累计用时、ETA 范围和预计完成时间。
- 支持取消、失败块重试、文件夹递归队列，以及严格的模型 JSON/SRT 格式校验。
- 使用 Sparkle 2 + GitHub Releases 每日自动检查、签名验证、下载和安装更新，不需要自建服务器。
- macOS 15 及以上可直接使用 Apple Translation 批量进行本地字幕翻译；语言包由系统征得用户许可后下载，字幕正文不会上传。
- macOS 14、Apple Silicon 与 Intel Mac 仍保留 Codex 自动翻译和手动分段翻译；Apple 本地翻译入口会明确提示系统版本或语言组合不支持。

## Whisper 英语语音识别

模型不会预塞进 DMG，用户在 App 内选择后再下载，并在安装前校验官方文件大小和 SHA-1。Base 最轻最快但抗噪和口音较弱；Small 是默认的质量/速度平衡；Medium 更准确但明显更慢、更占内存；Large v3 Turbo 接近大型模型质量，在 Apple Silicon 上更合适，老 Intel Mac 不推荐。音频由内嵌 FFmpeg 转为 16 kHz 单声道后分段识别，原始视频不会被修改或重新编码。

## FFmpeg 与隐私

macOS App/DMG 已内嵌精简的 FFmpeg 8.1.2 与 ffprobe，无需用户安装 Homebrew。内嵌版本为 Universal 2，仅启用本地 Matroska、SRT、ASS、WebVTT、SUP 和所需字幕编解码功能；网络、GPL、nonfree 和外部编码器均关闭。

应用仍会检测系统 `mkvextract`，存在时优先用它快速提取；它是可选加速组件。若内嵌工具因包损坏而缺失，应用才回退到 `/opt/homebrew/bin` 或 `/usr/local/bin` 中的 FFmpeg，并提供用户确认后的 Homebrew 安装入口，不会静默下载安装。

FFmpeg 的官方源码归档、校验值、许可证和可复现构建脚本均包含在仓库或安装包中，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## Codex 自动翻译

首次使用点击“连接 ChatGPT”，应用以参数数组异步启动 `codex login`，官方流程在浏览器中完成。也可在终端执行：

```sh
codex login
codex login status
```

应用不会读取、复制或解析 `auth.json`，不会读取浏览器 Cookie，也不会请求 API Key。翻译提示和字幕经 stdin 传给 `codex exec`；JSONL stdout 的最终消息会被严格解析。登录、额度、模型或服务不可用时会明确报错，不会偷偷回退到 API 或其他模型。

## 输出规则

默认生成与视频同目录的独立 SRT。目标为简体中文时，`Movie.mkv` 的仅译文输出为 `Movie.srt`，双语输出为 `Movie_zh_bilingual.srt`；其他目标语言使用对应代码，例如法语为 `_fr.srt`。iOS 直接导入字幕文件时会强制添加目标语言后缀，避免默认覆盖源字幕。播放器可自动匹配同名字幕，也可手动加载。

只有用户主动选择“重新封装 MKV”时，macOS 才使用 `-map 0 -map 1:0 -c copy` 保留全部原轨道并新增目标语言字幕轨道。原文件永不直接覆盖，视频和音频不重新编码。

## 构建与测试

需要 Xcode 16 或兼容的 Swift 5.10+ 工具链。用 Xcode 打开 `Package.swift` 并运行 `MKVSubtitleTranslator`，或执行：

```sh
zsh scripts/setup_dependencies.sh
swift run MKVSubtitleTranslator
swift test --disable-sandbox
```

构建 FFmpeg 和 Universal 2 DMG：

```sh
zsh scripts/build_ffmpeg_macos.sh
zsh scripts/package_dmg.sh
```

GitHub 自动更新的首次配置和发布步骤见 [UPDATE_SETUP.md](UPDATE_SETUP.md)。应用首页有独立“软件更新”区域，不与界面语言菜单混放。

构建 iOS arm64 框架和 LiveContainer IPA：

```sh
zsh scripts/build_ffmpeg_ios.sh
zsh scripts/package_ipa.sh
```

依赖准备脚本会校验 Whisper 1.9.2 与 Sparkle 2.9.6 官方归档的 SHA-256，再还原本地框架；FFmpeg 构建脚本也会先校验 `Vendor/Downloads/ffmpeg-8.1.2.tar.xz`。展开后的框架、构建工具和输出文件默认不提交 Git。

## 工程结构

- `Sources/MKVSubtitleCore/`：容器检查、字幕解析/写入、OCR、语言模型、翻译、进度和外部进程服务。
- `Sources/MKVSubtitleTranslatorApp/`：macOS SwiftUI 界面与 ViewModel。
- `iOS/Sources/`：iOS 手动翻译界面、原地文件访问、工作区持久化和原生 FFmpeg 桥接。
- `Tests/MKVSubtitleCoreTests/`：解析、时间轴、分块、验证、Codex JSONL、参数、安全和持久化测试。
- `scripts/`：macOS/iOS FFmpeg 构建及 DMG/IPA 打包。
- `Vendor/MKVFFmpeg/`：iOS C 桥、FFmpeg 构建说明与许可证资料。

## 已知限制

- DVB 和 XSUB 图片字幕尚不支持 OCR；PGS 与 VobSub/DVD 已支持本地 OCR。
- PGS OCR 无法保留图片字幕的字体、颜色和屏幕位置；复杂花体、低对比度和混合语言需要人工校对。
- WebVTT 支持常用 cue，复杂 REGION/STYLE/NOTE 尚未完整保真。
- 文本字幕当前自动识别 UTF-8/UTF-16；Windows-1252、GB18030、Shift-JIS 等旧编码需要先转换为 UTF-8。
- PGS 已设置文件、像素和内存安全上限；特别大的图片字幕轨道可能提示改选其他轨道，尚未实现真正的流式 SUP→OCR。
- 十种界面的主要控件已本地化；少数带文件名、数量或底层工具原文的动态状态/错误会回退到英文或简体中文。
- 中文片名推测仅在目标语言为简体中文时可用；尚未接入 TMDb 等联网元数据源。
- iOS 版目前以单文件手动翻译为核心，不含 Codex 自动翻译、文件夹队列或 MKV 重新封装。
- 测试 DMG 使用 ad-hoc 签名；公开发布前仍建议配置 Developer ID 与 Apple 公证，避免 Gatekeeper 警告。Sparkle/GitHub 自动更新已接入，但 Release 构建前必须按 `UPDATE_SETUP.md` 配置仓库和私钥 Secret。
- 项目自身尚未选择开源许可证；公开仓库前应由所有者添加合适的根 `LICENSE`。
