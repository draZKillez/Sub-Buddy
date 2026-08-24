# Sub Buddy / 字幕搭档 iOS

iOS 0.4.0 面向 LiveContainer 真机测试，最低 iOS/iPadOS 16，输出未签名 arm64 IPA。当前核心是单文件手动字幕翻译，不含 Codex 自动翻译、文件夹队列或 MKV 重新封装。

## 工作流

1. 从系统“文件”原地选择 MKV、SRT、ASS/SSA、WebVTT 或 PGS `.sup`，大型 MKV 不会先复制到应用沙盒。
2. 选择源语言与目标语言。两侧均提供英语、简体中文、西班牙语、法语、德语、日语、韩语、葡萄牙语、俄语和阿拉伯语。
   App 界面语言可在右上角独立选择相同十种语言，不会改变字幕设置。
3. 内嵌 FFmpeg 读取 MKV 元数据与字幕轨道，并优先选择与源语言匹配的文本字幕。
4. 提取文本字幕；PGS 则使用所选源语言的 Apple Vision 本机 OCR。
5. 按 1–1000 条拆分，默认 500；逐份复制完整提示、粘贴译文并校验保存。
6. 本地校验数量、ID、顺序、时间轴、额外说明和空正文，并修复常见的 `->`、`→`、全角时间轴标点。
7. 自动保存和恢复分段进度；不同语言组合不会误用彼此进度。
8. 导出仅译文或双语 SRT。原始 MKV 永不修改或覆盖。

## 本机媒体组件

- FFmpeg 8.1.2 以 iOS arm64 动态框架内嵌，无需用户安装。
- 仅启用本地文件协议、Matroska 和所需字幕组件；关闭 GPL、nonfree、网络和不相关编解码功能。
- 非目标视频、音频流在 demux 层丢弃，避免把媒体包传入 Swift。
- IPA 内包含 LGPL 2.1+ 许可证、版本、构建配置和源码获取说明。

## 进度与限制

- 提取/OCR 显示百分比、完成/剩余数量、累计用时、ETA 和预计完成时间，并支持取消。
- 长任务期间阻止设备自动锁屏；iOS 仍可能在后台或锁屏后暂停任务。
- PGS 与 VobSub/DVD 支持本机 OCR；DVB、XSUB 暂不支持。
- PGS OCR 准确度取决于字体、对比度和 Apple Vision 对所选语言的支持，建议导出前人工校对。

## 构建

需要 Xcode 16 或更高版本：

```sh
zsh scripts/build_ffmpeg_ios.sh
zsh scripts/package_ipa.sh
```

输出为 `outputs/Sub-Buddy-iOS-0.4.0-LiveContainer.ipa`。
