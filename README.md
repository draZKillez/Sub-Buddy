# Sub Buddy / 字幕搭档

<p align="center">
  <img src="Branding/SubBuddy-AppIcon-1024.png" width="160" alt="Sub Buddy app icon">
</p>

**把视频里的字幕提取或识别出来，翻译后生成播放器可以直接使用的 SRT。**

**Extract or recognize subtitles from video, translate them, and export a ready-to-use SRT.**

[中文](#中文) · [English](#english)

> [!NOTE]
> 这是一个由真实使用需求推动、借助 Codex 协作开发的 vibe-coding 个人项目。维护者负责产品取舍、测试和最终判断，Codex 协助实现、重构与排错。项目仍在测试阶段，请先用可重新取得的媒体文件试用，并欢迎提交可复现的 Issue。

## 中文

### 它是做什么的？

Sub Buddy 是一款 macOS/iOS 字幕工具，核心功能是：

- 从 MKV 中读取并提取 SRT、ASS/SSA、WebVTT 文字字幕。
- 用 Apple Vision 在本机识别 PGS、VobSub/DVD 图片字幕。
- 用 whisper.cpp 在本机把英语音轨识别成字幕。
- 使用手动分段、Apple 本地翻译或 Codex 翻译字幕。
- 源语言、目标语言和界面语言分别支持英语、简体中文、西班牙语、法语、德语、日语、韩语、葡萄牙语、俄语和阿拉伯语。
- 导出纯译文或双语 SRT；默认不修改、不覆盖原始视频。
- macOS 版支持文件夹队列、进度保存、取消、重试和 GitHub 自动更新。

应用内嵌精简版 FFmpeg/ffprobe。macOS 安装包同时支持 Apple Silicon 和 Intel Mac。

### 怎么使用？

#### macOS

1. 从 [GitHub Releases](https://github.com/draZKillez/Sub-Buddy/releases) 下载 DMG，把 **Sub Buddy** 拖进“应用程序”。
2. 打开应用，把 MKV 或字幕文件拖进窗口。
3. 选择要处理的字幕轨道：
   - 普通文字字幕可以直接提取。
   - PGS/VobSub 图片字幕选择“本机 OCR”。
   - 没有字幕时，选择英语音轨和 Whisper 模型；不知道选什么就用默认的 **Small**。
4. 选择目标语言和翻译方式：
   - **手动模式**：复制应用拆好的每一份字幕，交给你常用的 AI 翻译，再把完整 SRT 粘贴回来。
   - **Apple 本地翻译**：按提示下载系统语言包，然后在设备上翻译。
   - **Codex**：先安装 Codex CLI，点击“连接 ChatGPT”完成官方登录，再开始自动翻译；不需要 API Key。
5. 选择“纯译文”或“双语”，点击生成 SRT。
6. 新 SRT 默认保存在视频旁边。播放器没有自动加载时，在播放器的字幕菜单里手动选择它。

原始 MKV 不会被直接覆盖。电影中文名、年份和每份字幕数量都是可选设置，不知道怎么填时保持默认即可。

#### iPhone / iPad

1. 在 App 中选择 MKV、SRT、ASS、VTT 或 SUP 文件。
2. 选择字幕轨道；图片字幕按提示在本机 OCR。
3. 按默认每份 500 条拆分，逐份复制、翻译、粘贴并保存。
4. 所有分段完成后，导出纯译文或双语 SRT。

iOS 测试版目前以单文件手动翻译为主，不包含 Codex 自动翻译、文件夹队列或 MKV 重新封装。

### 它是怎么实现的？

- **Swift + SwiftUI**：macOS 14+ 和 iOS 16+ 原生界面。
- **FFmpeg/ffprobe**：检查 MKV、提取字幕和音频；macOS 检测到 `mkvextract` 时会优先使用快速提取路径。
- **Apple Vision**：在设备上 OCR 图片字幕，图片不会上传。
- **whisper.cpp**：在设备上识别英语音轨；模型由用户选择并按需下载。
- **Apple Translation**：使用系统语言包进行本地翻译。
- **Codex CLI**：通过 `codex exec` 的 stdin 发送字幕文字，读取 JSONL 结果；应用不读取 `auth.json`、浏览器 Cookie 或访问令牌。
- **字幕校验器**：检查 ID、数量、时间轴、空正文和模型额外说明，并保存已完成进度。
- **Sparkle + GitHub Releases**：签名检查和自动更新。

只有用户主动选择 Codex 翻译时，当前字幕文字、前后文、片名和术语表才会发送给 Codex 服务。视频、音频、字幕图片、完整路径和登录凭据不会作为翻译内容发送。项目没有内置广告、遥测或自动切换到第三方翻译服务。

## English

### What does it do?

Sub Buddy is a subtitle utility for macOS and iOS. Its main features are:

- Read and extract SRT, ASS/SSA, and WebVTT subtitle tracks from MKV files.
- Recognize PGS and VobSub/DVD bitmap subtitles locally with Apple Vision.
- Transcribe an English audio track locally with whisper.cpp.
- Translate subtitles with manual batches, Apple on-device translation, or Codex.
- Choose among English, Simplified Chinese, Spanish, French, German, Japanese, Korean, Portuguese, Russian, and Arabic for source, target, and interface languages.
- Export translation-only or bilingual SRT files without modifying the original video.
- On macOS: folder queues, resumable progress, cancellation, retries, and GitHub-based updates.

A reduced FFmpeg/ffprobe build is bundled with the app. The macOS package is Universal 2 for Apple Silicon and Intel Macs.

### How do I use it?

#### macOS

1. Download the DMG from [GitHub Releases](https://github.com/draZKillez/Sub-Buddy/releases), then drag **Sub Buddy** into Applications.
2. Open the app and drop in an MKV or subtitle file.
3. Choose what to process:
   - Extract a normal text subtitle directly.
   - Choose local OCR for a PGS or VobSub track.
   - If there is no subtitle, choose an English audio track and a Whisper model. Use the default **Small** model if unsure.
4. Choose a target language and translation method:
   - **Manual**: copy each prepared batch to your preferred AI, then paste the complete translated SRT back into the app.
   - **Apple Translation**: approve the system language-pack download and translate on device.
   - **Codex**: install the Codex CLI, choose “Connect ChatGPT,” finish the official sign-in, and start. No API key is required.
5. Select translation-only or bilingual output and generate the SRT.
6. The SRT is saved beside the video by default. If the player does not load it automatically, select it from the player's subtitle menu.

The original MKV is never overwritten directly. Movie title, year, and batch size are optional; the defaults are fine for most users.

#### iPhone / iPad

1. Pick an MKV, SRT, ASS, VTT, or SUP file from Files.
2. Select a subtitle track; use the on-device OCR option for bitmap subtitles.
3. Keep the default 500-item batch size, then copy, translate, paste, and save each batch.
4. When every batch is complete, export a translation-only or bilingual SRT.

The current iOS test build focuses on one-file manual translation. It does not include automatic Codex translation, folder queues, or MKV remuxing.

### How does it work?

- **Swift + SwiftUI** provide native macOS 14+ and iOS 16+ interfaces.
- **FFmpeg/ffprobe** inspect MKV files and extract subtitle or audio streams; macOS prefers `mkvextract` when it is available.
- **Apple Vision** performs bitmap-subtitle OCR on device.
- **whisper.cpp** transcribes English audio locally with a user-selected model.
- **Apple Translation** uses system language packs for on-device translation.
- **Codex CLI** receives subtitle text through `codex exec` stdin and returns JSONL. The app never reads `auth.json`, browser cookies, or access tokens.
- **Subtitle validation** checks IDs, counts, timelines, empty text, and unwanted model explanations while saving completed work.
- **Sparkle + GitHub Releases** provide signed updates without a dedicated server.

Only the Codex translation mode sends subtitle text, context, movie-title fields, and the glossary to the Codex service. Video, audio, subtitle images, full file paths, and login credentials are not sent as translation input. The app contains no ads or telemetry and never silently switches translation providers.

## Download and requirements

- macOS 14 or later; macOS 15+ is required for Apple Translation.
- Universal 2 support for Apple Silicon and Intel Mac.
- iOS/iPadOS 16+ for the unsigned LiveContainer test IPA.
- Current test DMGs use ad-hoc signing and are not notarized. The first launch may require approval in **System Settings → Privacy & Security**.

## Build and test

```sh
zsh scripts/setup_dependencies.sh
swift test --disable-sandbox
zsh scripts/package_dmg.sh
zsh scripts/package_ipa.sh
```

Pinned third-party versions, licenses, and source-relinking information are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Sparkle release setup is documented in [UPDATE_SETUP.md](UPDATE_SETUP.md).

## Current limitations

- DVB and XSUB bitmap-subtitle OCR is not implemented.
- OCR and Whisper results depend on audio quality, typography, contrast, accents, and overlapping dialogue; review the SRT before relying on it.
- Complex WebVTT REGION/STYLE/NOTE content is not fully preserved.
- The project is still a personal test build, not a commercial or unattended production tool.

When reporting an Issue, include the device, OS version, subtitle codec, expected result, actual result, and the smallest reproducible sample you can safely share. Never upload Codex login files or tokens.
