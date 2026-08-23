import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MKVSubtitleCore

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @EnvironmentObject private var updateController: UpdateController
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var interfaceLanguage: AppInterfaceLanguage = .simplifiedChinese
    @State private var isDropTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header
                updatePanel
                dropZone
                if !viewModel.batchJobs.isEmpty || viewModel.isScanningFolder { batchQueue }
                toolStatus
                if let info = viewModel.mediaInfo {
                    fileInformation(info)
                    subtitleTracks(info)
                    movieMetadata
                    speechRecognition(info)
                    translationControls
                }
                if let error = viewModel.errorMessage { errorPanel(error) }
                if let output = viewModel.outputURL { completionPanel(output) }
            }
            .padding(24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .groupBoxStyle(TranslatorCardGroupBoxStyle())
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            appleTranslationHost
        }
        .environment(\.locale, interfaceLanguage.locale)
        .environment(\.layoutDirection, interfaceLanguage == .arabic ? .rightToLeft : .leftToRight)
        .tint(Color(red: 0.18, green: 0.38, blue: 0.82))
        .alert(AppInterfaceLanguage.localized("输出文件已存在"), isPresented: $viewModel.showOverwriteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("覆盖输出文件", role: .destructive) { viewModel.startTranslation(overwrite: true) }
        } message: {
            Text(viewModel.overwriteExplanation)
        }
        .alert(AppInterfaceLanguage.localized("手动翻译输出已存在"), isPresented: $viewModel.showManualOverwriteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("覆盖输出文件", role: .destructive) { viewModel.finalizeManualTranslation(overwrite: true) }
        } message: {
            Text(viewModel.overwriteExplanation)
        }
        .alert(AppInterfaceLanguage.localized("英文字幕已存在"), isPresented: $viewModel.showSpeechOverwriteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("覆盖英文字幕", role: .destructive) { viewModel.startSpeechRecognition(overwrite: true) }
        } message: {
            Text("只会覆盖已有的同名 .en.srt，原始 MKV 不会被修改。")
        }
        .alert(AppInterfaceLanguage.localized("安装 FFmpeg？"), isPresented: $viewModel.showFFmpegInstallConfirmation) {
            Button("取消", role: .cancel) {}
            Button("使用 Homebrew 安装") { viewModel.installFFmpeg() }
        } message: {
            Text("应用将直接运行 brew install ffmpeg。Homebrew 会从网络下载安装，耗时取决于网络；应用不会使用管理员密码或静默安装其他软件。")
        }
        .alert(AppInterfaceLanguage.localized("需要先安装 Homebrew"), isPresented: $viewModel.showHomebrewRequired) {
            Button("取消", role: .cancel) {}
            Button("复制命令并打开官网") { viewModel.openHomebrewInstructions() }
        } message: {
            Text("系统中未检测到 Homebrew。点击后会复制 Homebrew 官方安装命令并打开 brew.sh；完成安装后回到应用点击“重新检测”。")
        }
        .alert(AppInterfaceLanguage.localized("安装 MKVToolNix 加速组件？"), isPresented: $viewModel.showMKVToolNixInstallConfirmation) {
            Button("取消", role: .cancel) {}
            Button("使用 Homebrew 安装") { viewModel.installMKVToolNix() }
        } message: {
            Text("应用将运行 brew install mkvtoolnix。安装后会优先使用 mkvextract 快速分离字幕；这是可选加速组件，未安装时仍会回退 FFmpeg。")
        }
    }

    private var header: some View {
        HStack {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(0.18))
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 5) {
                Text("AI看剧伴侣").font(.largeTitle.bold()).foregroundStyle(.white)
                Text("AI Viewing Companion · 本地字幕生成与翻译").foregroundStyle(.white.opacity(0.82))
            }
            Spacer()
            Menu {
                Picker("界面语言", selection: $interfaceLanguage) {
                    ForEach(AppInterfaceLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
            } label: {
                Label(interfaceLanguage.nativeName, systemImage: "globe")
                    .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .help(AppInterfaceLanguage.localized("界面语言"))
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.32, blue: 0.72), Color(red: 0.35, green: 0.22, blue: 0.68)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20)
        )
    }

    private var updatePanel: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("软件更新")
                    .font(.headline)
                Text(updateController.configurationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(AppInterfaceLanguage.localized("版本")) \(updateController.currentVersion)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("检查更新…") {
                updateController.checkForUpdates()
            }
            .buttonStyle(.bordered)
            .disabled(!updateController.canCheckForUpdates)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var appleTranslationHost: some View {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            AppleTranslationHost(
                sourceLanguage: viewModel.sourceLanguage,
                targetLanguage: viewModel.targetLanguage
            )
        }
#endif
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
            .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [8]))
            .frame(height: 145)
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 34)).foregroundStyle(.tint)
                    Text(viewModel.selectedFile?.lastPathComponent ?? viewModel.selectedFolder?.lastPathComponent ?? "将 MKV 文件拖到这里").font(.headline)
                    Text("支持中文、空格及特殊字符文件名").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("选择 MKV…") { chooseFile() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isMediaBusy || viewModel.isInspecting || viewModel.isScanningFolder)
                        Button("选择文件夹…") { chooseFolder() }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isMediaBusy || viewModel.isInspecting || viewModel.isScanningFolder)
                    }
                }
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                guard !viewModel.isMediaBusy, !viewModel.isInspecting, !viewModel.isScanningFolder else { return false }
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in viewModel.loadFile(url) }
                }
                return true
            }
    }

    private var batchQueue: some View {
        GroupBox("文件夹任务队列") {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.isScanningFolder {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在递归扫描文件夹并读取字幕轨道…")
                    }
                }
                if !viewModel.batchJobs.isEmpty {
                    HStack {
                        Text(viewModel.selectedFolder?.path ?? "已恢复上次队列")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("完成 \(viewModel.completedBatchJobCount)/\(viewModel.batchJobs.count) · 失败 \(viewModel.failedBatchJobCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: viewModel.batchProgressFraction)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(viewModel.batchJobs) { job in
                                HStack(spacing: 9) {
                                    Button {
                                        viewModel.toggleBatchJob(job.id)
                                    } label: {
                                        Image(systemName: job.isEnabled ? "checkmark.circle.fill" : "circle")
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(
                                        viewModel.isWorking || viewModel.isBatchProcessing || viewModel.isScanningFolder ||
                                        viewModel.isInspecting || job.status == .completed
                                    )
                                    VStack(alignment: .leading, spacing: 2) {
                                        Button(job.fileName) { viewModel.loadBatchJob(job.id) }
                                            .buttonStyle(.plain)
                                            .lineLimit(1)
                                            .disabled(
                                                viewModel.isWorking || viewModel.isBatchProcessing || viewModel.isScanningFolder ||
                                                viewModel.isInspecting
                                            )
                                        Text("\(job.status.displayName) · \(job.detail)")
                                            .font(.caption)
                                            .foregroundStyle(job.status == .failed ? Color.red : Color.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if job.status == .processing { ProgressView().controlSize(.small) }
                                    Text("\(Int((job.progressFraction * 100).rounded()))%")
                                        .font(.caption.monospacedDigit())
                                        .frame(width: 38, alignment: .trailing)
                                }
                                .padding(8)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(maxHeight: 230)
                    HStack {
                        if viewModel.workflowMode != .manual {
                            Picker("已有输出", selection: $viewModel.batchExistingFilePolicy) {
                                ForEach(BatchExistingFilePolicy.allCases) { policy in
                                    Text(policy.displayName).tag(policy)
                                }
                            }
                            .frame(width: 180)
                            .disabled(
                                viewModel.isWorking || viewModel.isBatchProcessing ||
                                viewModel.isScanningFolder || viewModel.isInspecting
                            )
                            Button(viewModel.isBatchProcessing ? "正在处理队列…" : "开始处理队列") {
                                viewModel.startBatchProcessing()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                viewModel.isWorking || viewModel.isBatchProcessing || viewModel.isScanningFolder ||
                                viewModel.isInspecting || viewModel.enabledBatchJobCount == 0 ||
                                !viewModel.ffmpegReady || !viewModel.selectedTranslationProviderIsReady ||
                                !viewModel.chunkSizeIsValid || !viewModel.languagePairIsValid
                            )
                        } else {
                            Label("手动模式按文件逐个处理；点击文件名切换当前文件。", systemImage: "hand.point.up.left")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("清空队列") { viewModel.clearBatchQueue() }
                            .disabled(
                                viewModel.isWorking || viewModel.isBatchProcessing ||
                                viewModel.isScanningFolder || viewModel.isInspecting
                            )
                    }
                }
            }
        }
    }

    private var toolStatus: some View {
        GroupBox("运行环境") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    environmentTile(
                        icon: "film.stack.fill",
                        name: "媒体工具",
                        ready: viewModel.ffmpegReady,
                        detail: mediaToolsDetail
                    )
                    environmentTile(
                        icon: "sparkles",
                        name: viewModel.workflowMode == .appleLocal ? "Apple 本地翻译" : "ChatGPT / Codex",
                        ready: viewModel.selectedTranslationProviderIsReady,
                        detail: translationEnvironmentDetail
                    )
                }

                HStack {
                    if !viewModel.ffmpegReady {
                        Label(
                            viewModel.tools.homebrew == nil ? "未检测到 Homebrew" : "已检测到 Homebrew，可由应用安装 FFmpeg",
                            systemImage: "info.circle"
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        Button(viewModel.isInstallingFFmpeg ? "正在安装…" : "安装 FFmpeg") {
                            viewModel.requestFFmpegInstallation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isInstallingFFmpeg || viewModel.isInstallingMKVToolNix || viewModel.isWorking)
                    } else if !viewModel.mkvExtractReady {
                        Label("可选安装 MKVToolNix，让 MKV 字幕提取更快", systemImage: "bolt.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(viewModel.isInstallingMKVToolNix ? "正在安装…" : "安装加速组件") {
                            viewModel.requestMKVToolNixInstallation()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isInstallingMKVToolNix || viewModel.isInstallingFFmpeg || viewModel.isWorking)
                    }
                    Spacer()
                    Button(viewModel.isLoggingIn ? "正在等待登录…" : "连接 ChatGPT") { viewModel.connectChatGPT() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.tools.codex == nil || viewModel.isLoggingIn || viewModel.isWorking || viewModel.isInstallingFFmpeg || viewModel.isInstallingMKVToolNix)
                    Button("重新检测") { Task { await viewModel.refreshEnvironment() } }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isLoggingIn || viewModel.isWorking || viewModel.isInstallingFFmpeg || viewModel.isInstallingMKVToolNix)
                }

                if viewModel.isInstallingFFmpeg {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Homebrew 正在安装 FFmpeg，请保持应用开启…")
                            .font(.callout)
                        Spacer()
                    }
                }
                if viewModel.isInstallingMKVToolNix {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Homebrew 正在安装 MKVToolNix，请保持应用开启…")
                            .font(.callout)
                        Spacer()
                    }
                }
                if !viewModel.ffmpegInstallLog.isEmpty {
                    Text(viewModel.ffmpegInstallLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
                if !viewModel.mkvToolNixInstallLog.isEmpty {
                    Text(viewModel.mkvToolNixInstallLog)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var translationEnvironmentDetail: String {
        switch viewModel.workflowMode {
        case .automatic:
            return viewModel.codexStatus.displayName
        case .appleLocal:
            return viewModel.appleLocalTranslationStatus.displayName
        case .manual:
            return "手动模式无需登录；AI 格式复核为可选"
        }
    }

    private func fileInformation(_ info: MediaInfo) -> some View {
        GroupBox("文件信息") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                GridRow { Text("文件").foregroundStyle(.secondary); Text(info.fileURL.path).textSelection(.enabled) }
                GridRow { Text("容器标题").foregroundStyle(.secondary); Text(info.containerTitle ?? "未设置") }
                GridRow { Text("字幕轨道").foregroundStyle(.secondary); Text("\(info.subtitleTracks.count) 条") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        }
    }

    private func subtitleTracks(_ info: MediaInfo) -> some View {
        GroupBox("字幕轨道（可手动选择）") {
            VStack(spacing: 0) {
                HStack {
                    Text("选择").frame(width: 44); Text("编号").frame(width: 44); Text("编码").frame(width: 105, alignment: .leading)
                    Text("语言").frame(width: 65, alignment: .leading); Text("名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("默认").frame(width: 45); Text("强制").frame(width: 45); Text("SDH").frame(width: 45)
                }.font(.caption).foregroundStyle(.secondary).padding(.vertical, 6)
                Divider()
                ForEach(info.subtitleTracks) { track in
                    Button {
                        if track.isProcessable { viewModel.selectSubtitleTrack(track.streamIndex) }
                    } label: {
                        HStack {
                            Image(systemName: viewModel.selectedTrackIndex == track.streamIndex ? "largecircle.fill.circle" : "circle")
                                .frame(width: 44)
                            Text("\(track.streamIndex)").frame(width: 44)
                            Text(track.codec).frame(width: 105, alignment: .leading)
                            Text(track.language).frame(width: 65, alignment: .leading)
                            Text(track.title.isEmpty ? "—" : track.title).frame(maxWidth: .infinity, alignment: .leading)
                            check(track.isDefault); check(track.isForced); check(track.isSDH)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .disabled(!track.isProcessable || viewModel.isWorking || viewModel.isInspecting)
                    Divider()
                }
                if info.subtitleTracks.contains(where: \.supportsLocalOCR) {
                    Label("检测到 PGS 或 VobSub 图片字幕，可使用 Apple Vision 在本机 OCR；图片不会上传。", systemImage: "text.viewfinder")
                        .foregroundStyle(.blue).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }
                if info.subtitleTracks.contains(where: { !$0.isText && !$0.supportsLocalOCR }) {
                    Label("DVB、XSUB 等其他图片字幕暂未支持 OCR。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
        }
    }

    private var movieMetadata: some View {
        GroupBox("电影信息（作为固定翻译上下文）") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow { Text("原始片名"); TextField("Original title", text: $viewModel.movie.originalTitle) }
                    GridRow {
                        Text("目标语言片名（可选）")
                        HStack {
                            TextField("可以留空，也可以手动填写", text: $viewModel.movie.chineseTitle)
                            Button(viewModel.isResolvingChineseTitle ? "正在推测…" : "推测中文片名") {
                                viewModel.suggestChineseTitles()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                viewModel.targetLanguage != .simplifiedChinese ||
                                viewModel.codexStatus != .loggedIn ||
                                viewModel.isResolvingChineseTitle ||
                                viewModel.isWorking
                            )
                        }
                    }
                    GridRow {
                        Text("年份")
                        TextField("年份", value: $viewModel.movie.year, format: .number.grouping(.never)).frame(width: 110)
                    }
                }
                if !viewModel.movie.chineseTitleCandidates.isEmpty {
                    HStack {
                        Text("候选（点击确认）").font(.caption).foregroundStyle(.secondary)
                        ForEach(viewModel.movie.chineseTitleCandidates, id: \.self) { candidate in
                            Button(candidate) { viewModel.movie.chineseTitle = candidate }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    }
                }
            }.padding(.vertical, 5)
        }
    }

    private func speechRecognition(_ info: MediaInfo) -> some View {
        GroupBox("从英语音轨生成字幕（Whisper）") {
            VStack(alignment: .leading, spacing: 12) {
                if info.audioTracks.isEmpty {
                    Label("这个文件没有可用的音频轨道。", systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                } else {
                    LabeledContent("英语音轨") {
                        Picker("英语音轨", selection: $viewModel.selectedAudioTrackIndex) {
                            Text("请选择音轨").tag(Int?.none)
                            ForEach(info.audioTracks) { track in
                                Text(audioTrackLabel(track)).tag(Optional(track.streamIndex))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 520)
                        .disabled(viewModel.isMediaBusy)
                        .onChange(of: viewModel.selectedAudioTrackIndex) { _, newValue in
                            if let newValue { viewModel.selectAudioTrack(newValue) }
                        }
                    }

                    LabeledContent("本地模型") {
                        Picker("Whisper 模型", selection: $viewModel.whisperModel) {
                            ForEach(WhisperModel.allCases) { model in
                                Text("\(model.displayName) · \(model.downloadSizeText)").tag(model)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 420)
                        .disabled(viewModel.downloadingWhisperModel != nil || viewModel.isSpeechRecognizing)
                        .onChange(of: viewModel.whisperModel) { _, _ in viewModel.whisperModelDidChange() }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Label("优势：\(viewModel.whisperModel.strengths)", systemImage: "checkmark.circle")
                        Label("不足：\(viewModel.whisperModel.limitations)", systemImage: "exclamationmark.circle")
                        Label("下载：\(viewModel.whisperModel.downloadSizeText)；仅第一次使用需要下载，识别过程完全在本机。", systemImage: "internaldrive")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        whisperModelStatus
                        Spacer()
                        if viewModel.downloadingWhisperModel != nil {
                            Button("取消下载", role: .cancel) { viewModel.cancelWhisperModelDownload() }
                        } else if viewModel.whisperModelState == .installed {
                            Button("删除模型", role: .destructive) { viewModel.deleteSelectedWhisperModel() }
                        } else {
                            Button(viewModel.whisperModelState == .damaged ? "重新下载模型" : "下载所选模型") {
                                viewModel.downloadSelectedWhisperModel()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    if viewModel.downloadingWhisperModel != nil {
                        ProgressView(value: viewModel.whisperDownloadProgress)
                        Text("已下载 \(Int((viewModel.whisperDownloadProgress * 100).rounded()))% · 请保持应用开启")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !viewModel.whisperStatusMessage.isEmpty {
                        Text(viewModel.whisperStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                    LabeledContent("输出位置") {
                        Text(viewModel.speechOutputPathText)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    Text("输出是独立的新英文 SRT（.en.srt），不会修改或重新封装 MKV；之后可在本应用里继续翻译字幕。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if viewModel.isSpeechRecognizing {
                        ProgressView(value: viewModel.speechRecognitionProgress.fraction)
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(speechPhaseTitle).font(.headline)
                                Text(viewModel.speechRecognitionProgress.detail).font(.callout)
                                Text("完成 \(Int((viewModel.speechRecognitionProgress.fraction * 100).rounded()))% · 大模型和 Intel Mac 所需时间会更长")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("取消识别", role: .cancel) { viewModel.cancelSpeechRecognition() }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                        }
                    } else {
                        HStack {
                            if let output = viewModel.speechOutputURL {
                                Label("英文字幕已生成：\(output.lastPathComponent)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Button("在 Finder 中显示") { viewModel.revealSpeechOutput() }
                            }
                            Spacer()
                            Button("识别英语音轨并生成 SRT") { viewModel.requestSpeechRecognition() }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    viewModel.selectedAudioTrack == nil || !viewModel.ffmpegReady ||
                                    viewModel.whisperModelState != .installed || viewModel.isWorking ||
                                    viewModel.downloadingWhisperModel != nil
                                )
                        }
                    }
                    if let error = viewModel.speechRecognitionError {
                        Label(error, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    private var translationControls: some View {
        GroupBox("翻译与输出") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("翻译语言") {
                    HStack(spacing: 8) {
                        Picker("原文语言", selection: $viewModel.sourceLanguage) {
                            ForEach(SubtitleLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .frame(width: 150)
                        Text("→").foregroundStyle(.secondary)
                        Picker("目标语言", selection: $viewModel.targetLanguage) {
                            ForEach(SubtitleLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .frame(width: 150)
                    }
                    .disabled(viewModel.isWorking || viewModel.manualSession != nil)
                    .onChange(of: viewModel.sourceLanguage) { _, _ in viewModel.languageSettingsDidChange() }
                    .onChange(of: viewModel.targetLanguage) { _, _ in viewModel.languageSettingsDidChange() }
                }
                if !viewModel.languagePairIsValid {
                    Label("原文语言和目标语言不能相同。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                LabeledContent("翻译模式") {
                    Picker("翻译模式", selection: $viewModel.workflowMode) {
                        ForEach(TranslationWorkflowMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    .disabled(viewModel.isWorking)
                    .onChange(of: viewModel.workflowMode) { _, _ in
                        viewModel.workflowModeDidChange()
                    }
                }
                if viewModel.workflowMode == .automatic {
                    LabeledContent("Codex 模型") {
                        HStack(spacing: 10) {
                            Picker("Codex 模型", selection: $viewModel.codexModel) {
                                ForEach(CodexModel.allCases) { model in
                                    Text(model.displayName).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 260)
                            .disabled(viewModel.isWorking)
                            .onChange(of: viewModel.codexModel) { _, _ in
                                viewModel.codexModelDidChange()
                            }
                            Text(viewModel.codexModel.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if viewModel.workflowMode == .appleLocal {
                    LabeledContent("本地翻译状态") {
                        HStack(spacing: 8) {
                            Image(systemName: viewModel.appleLocalTranslationStatus.isReady
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill")
                                .foregroundStyle(viewModel.appleLocalTranslationStatus.isReady ? Color.green : Color.orange)
                            Text(viewModel.appleLocalTranslationStatus.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("输出方式") {
                    Picker("输出方式", selection: $viewModel.deliveryMode) {
                        ForEach(DeliveryMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                    .disabled(viewModel.isWorking)
                    .onChange(of: viewModel.deliveryMode) { _, _ in
                        viewModel.outputSettingsDidChange()
                    }
                }
                LabeledContent("字幕内容") {
                    Picker("字幕内容", selection: $viewModel.subtitleOutputMode) {
                        ForEach(SubtitleOutputMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .disabled(viewModel.isWorking)
                    .onChange(of: viewModel.subtitleOutputMode) { _, _ in
                        viewModel.outputSettingsDidChange()
                    }
                }
                LabeledContent("每块字幕数量") {
                    HStack(spacing: 8) {
                        TextField("500", value: $viewModel.translationChunkSize, format: .number.grouping(.never))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .disabled(viewModel.isWorking)
                        Text("条（1–1000，默认 500）")
                            .font(.caption)
                            .foregroundStyle(viewModel.chunkSizeIsValid ? Color.secondary : Color.red)
                    }
                }
                if viewModel.workflowMode == .automatic {
                    Label(
                        "每块会通过一次 stdin 整批提交给 Codex；自动模式固定使用低延迟推理，不继承 Codex 的高推理设置。",
                        systemImage: "bolt.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if viewModel.workflowMode == .appleLocal {
                    Label(
                        "字幕正文由 macOS 在本机批量翻译，不会上传；系统语言包缺失时会先征求下载许可。片名上下文和术语表不会发送到 Apple Translation。",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                LabeledContent("输出位置") { Text(viewModel.outputPathText).textSelection(.enabled).foregroundStyle(.secondary) }
                outputExplanation
                if viewModel.isWorking {
                    if let fraction = viewModel.progress.phaseFraction,
                       viewModel.progress.phase == .extracting || viewModel.progress.phase == .ocr || viewModel.progress.phase == .muxing {
                        ProgressView(value: fraction)
                    } else if viewModel.progress.phase == .translating, viewModel.progress.totalItems > 0 {
                        ProgressView(
                            value: Double(viewModel.progress.completedItems),
                            total: Double(viewModel.progress.totalItems)
                        )
                    } else {
                        ProgressView()
                    }
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progressTitle)
                                .font(.headline)
                            if let detail = viewModel.progress.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.callout)
                            }
                            Text(progressSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("累计用时：\(viewModel.elapsedTimeText) · 预计剩余：\(viewModel.estimatedRemainingText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("预计完成：\(viewModel.estimatedCompletionText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消", role: .cancel) { viewModel.cancel() }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                    }
                } else {
                    if viewModel.workflowMode == .manual {
                        ManualTranslationView(viewModel: viewModel)
                    } else {
                        HStack {
                            Spacer()
                            Button(viewModel.deliveryMode == .sidecarSRT ? "开始翻译并生成 SRT" : "开始翻译并封装") {
                                viewModel.requestTranslation()
                            }
                                .buttonStyle(.borderedProminent)
                                .disabled(
                                    viewModel.selectedTrack == nil || viewModel.isInspecting ||
                                    !viewModel.ffmpegReady || !viewModel.selectedTranslationProviderIsReady ||
                                    !viewModel.chunkSizeIsValid || !viewModel.languagePairIsValid
                                )
                        }
                    }
                }
            }.padding(.vertical, 5)
        }
    }

    private func errorPanel(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(error).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if viewModel.canRetryCurrentWorkflow && !viewModel.isWorking {
                Button("重试") { viewModel.retryCurrentWorkflow() }
            }
        }.padding(12).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func completionPanel(_ output: URL) -> some View {
        let deliveryMode = viewModel.completedDeliveryMode ?? .sidecarSRT
        let outputMode = viewModel.completedOutputMode ?? .pureChinese
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(deliveryMode == .sidecarSRT ? "SRT 字幕生成完成" : "翻译和无损封装完成").font(.headline)
                Text(output.lastPathComponent).textSelection(.enabled)
                if let completion = viewModel.completionTimeText {
                    Text("累计用时：\(viewModel.elapsedTimeText) · 完成时间：\(completion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if deliveryMode == .sidecarSRT {
                    Text("这是独立的\(outputMode.displayName)字幕文件，原始 MKV 没有被重新封装或修改。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("字幕位于视频同一目录；简体中文仅译文与视频同名，其他语言或双语会带语言后缀。播放器未自动加载时，请手动选择这个 SRT。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("已新增“\(viewModel.trackTitle(for: outputMode))”字幕轨道；原字幕及原始 MKV 均未被替换。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("用于封装的临时 SRT 已自动清理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("若播放器曾打开过同名旧输出，请关闭该文件后重新打开，避免播放器继续使用旧轨道缓存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("在 Finder 中显示") { viewModel.revealOutput() }
        }.padding(12).background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var outputExplanation: some View {
        VStack(alignment: .leading, spacing: 5) {
            if viewModel.deliveryMode == .sidecarSRT {
                Label(
                    "将生成 \(viewModel.temporarySubtitleFileName)，位于视频同一目录；语言后缀可避免不同译文互相覆盖。",
                    systemImage: "captions.bubble"
                )
                Label(
                    "这是独立的新 SRT，不会重新封装、替换或修改原始 MKV。",
                    systemImage: "doc.on.doc"
                )
                Label(
                    "多数播放器会自动加载；如未自动加载，请在播放器中手动选择这个 SRT。",
                    systemImage: "play.rectangle"
                )
            } else {
                Label(
                    "先生成临时 SRT \(viewModel.temporarySubtitleFileName)，再作为新字幕轨道加入 MKV。",
                    systemImage: "captions.bubble"
                )
                Label(
                    "新轨道名称为“\(viewModel.trackTitle(for: viewModel.subtitleOutputMode))”；原字幕和其他所有轨道都会保留。",
                    systemImage: "plus.rectangle.on.rectangle"
                )
                Label(
                    "输出是新的 MKV 文件，不替换原始文件；临时 SRT 在封装完成后自动清理。",
                    systemImage: "doc.on.doc"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func environmentTile(icon: String, name: String, ready: Bool, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(ready ? Color.green : Color.orange)
                .frame(width: 34, height: 34)
                .background((ready ? Color.green : Color.orange).opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    Circle().fill(ready ? Color.green : Color.orange).frame(width: 7, height: 7)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var mediaToolsDetail: String {
        if !viewModel.ffmpegReady { return "未检测到 FFmpeg，处理 MKV 前需要安装" }
        if viewModel.usesBundledFFmpeg { return "内置 FFmpeg / ffprobe 已就绪" }
        if viewModel.mkvExtractReady { return "FFmpeg 已就绪 · mkvextract 快速提取已启用" }
        return "FFmpeg 已就绪 · 当前使用兼容提取模式"
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        switch viewModel.whisperModelState {
        case .installed:
            Label("模型已安装并可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notDownloaded:
            Label("模型尚未下载", systemImage: "arrow.down.circle")
                .foregroundStyle(.orange)
        case .damaged:
            Label("模型文件不完整，需要重新下载", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var speechPhaseTitle: String {
        switch viewModel.speechRecognitionProgress.phase {
        case .extractingAudio: return "正在提取音频"
        case .loadingModel: return "正在载入 Whisper 模型"
        case .recognizing: return "正在本地识别英文对白"
        case .writing: return "正在生成英文 SRT"
        }
    }

    private func audioTrackLabel(_ track: AudioTrack) -> String {
        let language = track.language.isEmpty ? "und" : track.language
        let channels = track.channels.map { " · \($0) 声道" } ?? ""
        let title = track.title.isEmpty ? "" : " · \(track.title)"
        let defaultMark = track.isDefault ? " · 默认" : ""
        return "#\(track.streamIndex) · \(track.codec) · \(language)\(channels)\(title)\(defaultMark)"
    }

    private var progressTitle: String {
        let progress = viewModel.progress
        if let fraction = progress.phaseFraction,
           progress.phase == .extracting || progress.phase == .ocr || progress.phase == .muxing {
            return "\(progress.phase.rawValue) · \(Int((fraction * 100).rounded()))%"
        }
        return progress.phase.rawValue
    }

    private var progressSummary: String {
        let progress = viewModel.progress
        switch progress.phase {
        case .extracting:
            let percent = Int(((progress.phaseFraction ?? 0) * 100).rounded())
            return "已扫描 \(percent)% · 剩余 \(max(0, 100 - percent))% · 当文件较大请耐心等待。"
        case .ocr:
            let percent = Int(((progress.phaseFraction ?? 0) * 100).rounded())
            return "已识别 \(progress.completedItems)/\(progress.totalItems) 条 · \(percent)% · 全程在本机处理"
        case .translating:
            let remainingItems = max(0, progress.totalItems - progress.completedItems)
            let remainingChunks = max(0, progress.totalChunks - progress.completedChunks)
            return "已完成 \(progress.completedItems)/\(progress.totalItems) 条 · 剩余 \(remainingItems) 条 · 剩余 \(remainingChunks) 块"
        case .writingSubtitle:
            return "已翻译 \(progress.completedItems) 条 · 正在写入字幕文件和时间轴"
        case .muxing:
            let percent = Int(((progress.phaseFraction ?? 0) * 100).rounded())
            return "字幕共 \(progress.totalItems) 条 · 已封装 \(percent)% · 剩余 \(max(0, 100 - percent))%"
        case .completed:
            return "共处理 \(progress.completedItems) 条字幕"
        }
    }

    private func check(_ value: Bool) -> some View {
        Image(systemName: value ? "checkmark" : "minus").foregroundStyle(value ? .primary : .tertiary).frame(width: 45)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mkv") ?? .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { viewModel.loadFile(url) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url { viewModel.loadFolder(url) }
    }
}

private struct TranslatorCardGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .font(.headline)
            configuration.content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 7, y: 2)
    }
}
