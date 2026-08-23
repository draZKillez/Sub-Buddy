import SwiftUI
import UniformTypeIdentifiers

struct MobileContentView: View {
    @StateObject private var viewModel = MobileViewModel()
    @AppStorage(AppInterfaceLanguage.preferenceKey) private var interfaceLanguage: AppInterfaceLanguage = .simplifiedChinese
    @State private var showImporter = false
    @State private var showWorkspace = false
    @State private var pendingImportURL: URL?
    @State private var showWorkspaceReplacementConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    importCard
                    if viewModel.isBusy { progressCard }
                    if let info = viewModel.mediaInfo { mediaCard(info) }
                    if viewModel.mediaInfo != nil && !viewModel.hasWorkspace { movieCard }
                    if viewModel.hasWorkspace { workspaceCard }
                    statusCard
                    aboutCard
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(AppInterfaceLanguage.localized("AI看剧伴侣"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("界面语言", selection: $interfaceLanguage) {
                            ForEach(AppInterfaceLanguage.allCases) { language in
                                Text(language.nativeName).tag(language)
                            }
                        }
                    } label: {
                        Label(interfaceLanguage.nativeName, systemImage: "globe")
                    }
                }
                if viewModel.hasWorkspace || viewModel.mediaInfo != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("清空") { viewModel.clearWorkspace() }
                            .disabled(viewModel.isBusy)
                    }
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            SystemFilePicker(
                isPresented: $showImporter,
                onPick: requestImport,
                onCancel: { viewModel.fileSelectionCancelled() }
            )
            .ignoresSafeArea()
        }
        .fileExporter(
            isPresented: $viewModel.isExporting,
            document: viewModel.exportDocument,
            contentType: .subRipSubtitle,
            defaultFilename: viewModel.exportFilename
        ) { result in
            viewModel.handleExportResult(result)
        }
        .sheet(isPresented: $showWorkspace) {
            NavigationStack {
                ManualWorkspaceView(viewModel: viewModel)
            }
        }
        .alert("替换当前工作区？", isPresented: $showWorkspaceReplacementConfirmation) {
            Button("取消", role: .cancel) { pendingImportURL = nil }
            Button("替换并导入", role: .destructive) {
                guard let url = pendingImportURL else { return }
                pendingImportURL = nil
                viewModel.importFile(url)
            }
        } message: {
            Text("新文件确认可读取后，当前文件已经保存的分段译文会被清空。此操作不会修改原始媒体或字幕文件。")
        }
        .environment(\.locale, interfaceLanguage.locale)
        .environment(\.layoutDirection, interfaceLanguage == .arabic ? .rightToLeft : .leftToRight)
        .onOpenURL { url in
            requestImport(url)
        }
    }

    private func requestImport(_ url: URL) {
        if viewModel.hasWorkspace {
            pendingImportURL = url
            showWorkspaceReplacementConfirmation = true
        } else {
            viewModel.importFile(url)
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
            Text("从 MKV 到多语言字幕")
                .font(.title2.bold())
            Text("直接读取字幕轨道，拆成可复制的小份，校验译文后导出新的单语或双语 SRT。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var importCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("选择单个 MKV", systemImage: "film.stack")
                    .font(.headline)
                Text("FFmpeg 已内嵌在应用中，无需另外安装。也可直接导入 SRT、ASS/SSA、WebVTT 或 PGS SUP。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    languagePicker("原文语言", selection: $viewModel.sourceLanguage)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    languagePicker("翻译为", selection: $viewModel.targetLanguage)
                }
                .disabled(viewModel.isBusy || viewModel.hasWorkspace)
                .onChange(of: viewModel.sourceLanguage) { _ in viewModel.languageSelectionDidChange() }
                .onChange(of: viewModel.targetLanguage) { _ in viewModel.languageSelectionDidChange() }
                if !viewModel.languagePairIsValid {
                    Label("原文语言和目标语言不能相同。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                HStack {
                    Text("每份字幕数量")
                    Spacer()
                    TextField("500", value: $viewModel.chunkSize, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 82)
                        .disabled(viewModel.isBusy || viewModel.hasWorkspace)
                    Text("条")
                }
                Text("可填写 1–1000，默认 500。")
                    .font(.caption)
                    .foregroundStyle(viewModel.chunkSizeIsValid ? Color.secondary : Color.red)
                Button {
                    viewModel.fileSelectionStarted()
                    showImporter = true
                } label: {
                    Label("选择 MKV 或字幕文件", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(viewModel.isBusy || !viewModel.chunkSizeIsValid || !viewModel.languagePairIsValid)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var progressCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(AppInterfaceLanguage.localized(viewModel.workPhase.rawValue), systemImage: progressIcon)
                        .font(.headline)
                    Spacer()
                    Button("取消", role: .destructive) { viewModel.cancelCurrentOperation() }
                }
                if let fraction = viewModel.phaseFraction {
                    ProgressView(value: fraction)
                    Text("已完成 \(Int((fraction * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                } else {
                    ProgressView()
                }
                if viewModel.totalItems > 0 {
                    Text("已处理 \(viewModel.completedItems)/\(viewModel.totalItems) 条 · 剩余 \(max(0, viewModel.totalItems - viewModel.completedItems)) 条")
                }
                Text("累计用时：\(viewModel.elapsedText) · 预计剩余：\(viewModel.etaText)")
                Text("预计完成：\(viewModel.estimatedCompletionText)")
            }
            .font(.subheadline)
        }
    }

    private var progressIcon: String {
        switch viewModel.workPhase {
        case .inspecting: return "list.bullet.rectangle"
        case .extracting: return "arrow.down.doc"
        case .ocr: return "text.viewfinder"
        case .parsing: return "text.page"
        case .idle: return "checkmark.circle"
        }
    }

    private func mediaCard(_ info: MediaInfo) -> some View {
        VStack(spacing: 16) {
            GroupBox("文件信息") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(info.fileURL.lastPathComponent, systemImage: "film")
                        .font(.headline)
                    valueRow("容器标题", info.containerTitle ?? "未设置")
                    valueRow("影片时长", viewModel.durationDescription)
                    valueRow("字幕轨道", "\(info.subtitleTracks.count) 条")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }

            GroupBox("字幕轨道") {
                VStack(spacing: 8) {
                    ForEach(info.subtitleTracks) { track in
                        Button {
                            viewModel.selectTrack(track.streamIndex)
                        } label: {
                            trackRow(track)
                        }
                        .buttonStyle(.plain)
                        .disabled(!track.isProcessable || viewModel.isBusy || viewModel.hasWorkspace)
                    }
                    if info.subtitleTracks.contains(where: \.supportsLocalOCR) {
                        Label("PGS 与 VobSub 可在设备上使用 Apple Vision OCR；图片不会上传。", systemImage: "text.viewfinder")
                            .font(.footnote)
                            .foregroundStyle(.blue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if info.subtitleTracks.contains(where: { !$0.isText && !$0.supportsLocalOCR }) {
                        Label("DVB、XSUB 等图片字幕暂不支持 OCR。", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func trackRow(_ track: SubtitleTrack) -> some View {
        HStack(spacing: 10) {
            Image(systemName: viewModel.selectedTrackIndex == track.streamIndex ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(track.isProcessable ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("#\(track.streamIndex)").fontWeight(.semibold)
                    Text(track.codec).font(.caption.monospaced())
                    Text(track.language).font(.caption.bold())
                    if track.isDefault { badge("默认") }
                    if track.isForced { badge("强制") }
                    if track.isSDH { badge("SDH") }
                }
                Text(track.title.isEmpty ? (track.isProcessable ? "未命名字幕" : "当前编码不支持") : track.title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if track.supportsLocalOCR { Image(systemName: "text.viewfinder").foregroundStyle(.blue) }
        }
        .padding(10)
        .background(
            viewModel.selectedTrackIndex == track.streamIndex ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .opacity(track.isProcessable ? 1 : 0.55)
    }

    private var movieCard: some View {
        GroupBox("影视信息与提取") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("原始片名", text: $viewModel.movie.originalTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("目标语言片名（可不填）", text: $viewModel.movie.chineseTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("年份（可不填）", value: $viewModel.movie.year, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text("这些信息会写进复制给翻译工具的固定上下文；目标语言片名不是必填项。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    viewModel.prepareSelectedTrack()
                } label: {
                    Label(viewModel.selectedTrack?.supportsLocalOCR == true ? "提取并本机 OCR" : "提取并拆分字幕", systemImage: "arrow.down.doc.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canPrepareSelectedTrack)
            }
            .padding(.top, 8)
            .onChange(of: viewModel.movie.originalTitle) { _ in viewModel.metadataDidChange() }
            .onChange(of: viewModel.movie.chineseTitle) { _ in viewModel.metadataDidChange() }
            .onChange(of: viewModel.movie.year) { _ in viewModel.metadataDidChange() }
        }
    }

    private var workspaceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(viewModel.sourceName, systemImage: "captions.bubble")
                    .font(.headline)
                    .lineLimit(2)
                ProgressView(value: viewModel.progressFraction)
                Text(viewModel.completedText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !viewModel.lowConfidenceCueIDs.isEmpty {
                    Label("\(viewModel.lowConfidenceCueIDs.count) 条 OCR 结果需要重点校对", systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Button {
                    showWorkspace = true
                } label: {
                    Label("继续手动分段翻译", systemImage: "rectangle.and.pencil.and.ellipsis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(viewModel.statusMessage, systemImage: viewModel.isError ? "exclamationmark.triangle.fill" : "info.circle")
            if viewModel.completedAt != nil {
                Text("本次处理用时：\(viewModel.elapsedText) · 完成时间：\(viewModel.completionTimeText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .foregroundStyle(viewModel.isError ? Color.red : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("本机组件")
                .font(.footnote.bold())
            Text("FFmpeg \(viewModel.ffmpegVersion)（LGPL 2.1+）仅用于读取 MKV 和复制字幕数据；不会解码或重新编码视频。翻译采用手动复制粘贴，不连接 Codex，也不要求 API Key。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
    }

    private func languagePicker(_ title: String, selection: Binding<SubtitleLanguage>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: selection) {
                ForEach(SubtitleLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ManualWorkspaceView: View {
    @ObservedObject var viewModel: MobileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showRebuildConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataCard
                chunkCard
                if viewModel.isOCRSource { ocrReviewCard }
                copyCard
                pasteCard
                statusMessage
                if viewModel.session?.isComplete == true { exportCard }
            }
            .padding()
            .disabled(viewModel.isBusy)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(AppInterfaceLanguage.localized("手动翻译"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("完成") { dismiss() } }
    }

    private var metadataCard: some View {
        GroupBox("影视信息（可修改）") {
            VStack(spacing: 10) {
                TextField("原始片名", text: $viewModel.movie.originalTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("目标语言片名（可不填）", text: $viewModel.movie.chineseTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("年份（可不填）", value: $viewModel.movie.year, format: .number)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("输出内容")
                    Spacer()
                    Picker("输出内容", selection: $viewModel.outputMode) {
                        ForEach(SubtitleOutputMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }
            }
            .padding(.top, 8)
            .onChange(of: viewModel.movie.originalTitle) { _ in viewModel.metadataDidChange() }
            .onChange(of: viewModel.movie.chineseTitle) { _ in viewModel.metadataDidChange() }
            .onChange(of: viewModel.movie.year) { _ in viewModel.metadataDidChange() }
            .onChange(of: viewModel.outputMode) { _ in viewModel.metadataDidChange() }
        }
    }

    private var chunkCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.currentChunkLabel).font(.headline)
                ProgressView(value: viewModel.progressFraction)
                HStack {
                    Button("上一份") { viewModel.moveChunk(-1) }
                        .disabled(viewModel.session?.currentChunkIndex == 0)
                    Button("下一份") { viewModel.moveChunk(1) }
                        .disabled((viewModel.session?.currentChunkIndex ?? 0) + 1 >= (viewModel.session?.totalChunkCount ?? 0))
                }
                Divider()
                HStack {
                    Text("重新拆分每份")
                    Spacer()
                    TextField("500", value: $viewModel.rebuildChunkSize, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 82)
                    Text("条")
                    Button("重新拆分") { showRebuildConfirmation = true }
                        .disabled(
                            !viewModel.rebuildChunkSizeIsValid ||
                            viewModel.rebuildChunkSize == viewModel.session?.chunkSize
                        )
                }
                Text("重新拆分会清空所有已经保存的译文。")
                    .font(.footnote)
                    .foregroundStyle(viewModel.rebuildChunkSizeIsValid ? Color.secondary : Color.red)
            }
        }
        .alert("确认重新拆分？", isPresented: $showRebuildConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空译文并重拆", role: .destructive) {
                viewModel.rebuildChunks(using: viewModel.rebuildChunkSize)
            }
        } message: {
            Text("所有分段译文进度都会被清空，原始字幕不会改变。")
        }
    }

    private var ocrReviewCard: some View {
        GroupBox("PGS OCR 原文校对") {
            VStack(alignment: .leading, spacing: 8) {
                Text(ocrReviewGuidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.sourceReviewText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 180)
                    .padding(4)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                Button("校验并保存 OCR 原文") { viewModel.saveOCRCorrection() }
                    .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }

    private var ocrReviewGuidance: String {
        guard !viewModel.lowConfidenceCueIDs.isEmpty else {
            return "可以逐份检查并修改 OCR 正文，但不要改动序号和时间轴。"
        }
        return "可修改正文，但不要改动序号和时间轴。低置信度 ID：\(viewModel.lowConfidenceCueIDs.prefix(30).map(String.init).joined(separator: ", "))"
    }

    private var copyCard: some View {
        GroupBox("1. 复制给翻译工具") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(viewModel.copyText)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 230)
                Text("从当前份的第一个 ID 开始，包含完整序号和时间轴。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("复制本份完整文本") { viewModel.copyCurrentPrompt() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.top, 8)
        }
    }

    private var pasteCard: some View {
        GroupBox("2. 粘贴翻译后的 SRT") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $viewModel.pastedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 250)
                    .padding(4)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("从剪贴板粘贴") { viewModel.pasteFromClipboard() }
                    Spacer()
                    Button("校验并保存本份") { viewModel.saveCurrentTranslation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var statusMessage: some View {
        if !viewModel.statusMessage.isEmpty {
            Label(viewModel.statusMessage, systemImage: viewModel.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(viewModel.isError ? Color.red : Color.secondary)
        }
    }

    private var exportCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("所有分段均已通过本地格式校验", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("只导出一个新的 SRT；不会修改、替换或重新封装原始 MKV。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(viewModel.outputMode == .pureChinese && viewModel.targetLanguage == .simplifiedChinese
                     ? "简体中文字幕与视频文件名主体一致，播放器更容易自动识别。"
                     : "输出会增加 \(viewModel.outputMode.sidecarFileSuffix(targetLanguage: viewModel.targetLanguage)) 后缀，避免不同语言互相覆盖。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("合并并导出 \(viewModel.outputMode.displayName) SRT") { viewModel.exportMergedSRT() }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
