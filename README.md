# Sub Buddy / 字幕搭档

<p align="center">
  <img src="Branding/SubBuddy-AppIcon-1024.png" width="160" alt="Sub Buddy app icon">
</p>

## 1. 做什么 / What

Sub Buddy 是一个个人 vibe-coding 项目，提供 macOS 字幕提取、识别和翻译，导出单语或双语 SRT。

Sub Buddy is a personal vibe-coded project for extracting, recognizing and translating subtitles on macOS, with translation-only or bilingual SRT output.

## 2. 怎么用 / How

从 [Releases](https://github.com/draZKillez/Sub-Buddy/releases/latest) 下载 DMG，将 App 拖进“应用程序”。拖入 MKV、MP4 等视频，或选择文件夹批量处理。

Download the DMG from [Releases](https://github.com/draZKillez/Sub-Buddy/releases/latest) and drag the app into Applications. Drop in MKV, MP4 or other supported videos, or select a folder for batch processing.

文字字幕直接提取；图片字幕使用本地 OCR；没有字幕时，可用 Whisper 识别英语音轨。

Extract text subtitles directly, use local OCR for bitmap subtitles, or use Whisper to transcribe an English audio track when subtitles are missing.

选择目标语言，用 Codex 自动翻译、Apple 本地翻译，或手动分段复制给 AI，再粘贴回译文。可调模型、推理强度和分段数量，支持保存进度、取消与重试。

Choose a target language and translate automatically with Codex, locally with Apple Translation, or manually by copying each batch to an AI and pasting the translation back. Adjust the model, reasoning level and batch size; save progress, cancel or retry.

选择单语或双语，生成视频旁的 SRT，在播放器中加载即可，原视频保持不变。

Choose translation-only or bilingual output, generate an SRT beside the video, and load it in your player. The original video stays unchanged.

## 3. 原理与隐私 / Privacy

FFmpeg 处理媒体，OCR 和语音识别在本机完成。Codex 使用官方登录，应用不读取登录凭据；字幕与上下文会发往 OpenAI，不上传视频。

FFmpeg handles media processing, while OCR and speech recognition run locally. Codex uses official sign-in; Sub Buddy does not read login credentials. Subtitle text and context are sent to OpenAI, but video files are not uploaded.
