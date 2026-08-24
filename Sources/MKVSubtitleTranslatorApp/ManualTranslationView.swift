import SwiftUI
import MKVSubtitleCore

struct ManualTranslationView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Label("手动模式不需要连接 Codex。应用只负责拆分、校验和合并字幕。", systemImage: "hand.raised.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let session = viewModel.manualSession {
                sessionContent(session)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(AppInterfaceLanguage.localizedFormat(
                            "先提取所选字幕并按每份 %d 条拆分。",
                            viewModel.translationChunkSize
                        ))
                        Text("拆分完成后，可以逐份复制到任意 AI，再把保持 SRT 格式的译文粘贴回来。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("提取并拆分字幕") { viewModel.prepareManualTranslation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            viewModel.selectedTrack == nil || viewModel.isInspecting ||
                            !viewModel.ffmpegReady || !viewModel.chunkSizeIsValid ||
                            !viewModel.languagePairIsValid
                        )
                }
            }
        }
    }

    private func sessionContent(_ session: ManualTranslationSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sessionHeader(session)
            manualTimingSummary
            chunkPicker(session)
            if viewModel.selectedTrack?.supportsLocalOCR == true { ocrReview }
            if let chunk = session.currentChunk { currentChunkContent(chunk, session: session) }
            statusMessage
            if session.isComplete { completionActions }
        }
    }

    private var manualTimingSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(AppInterfaceLanguage.localizedFormat(
                "累计用时：%@ · 整体粗略剩余：%@",
                viewModel.elapsedTimeText,
                viewModel.overallEstimatedRemainingText
            ))
            Text(AppInterfaceLanguage.localizedFormat(
                "整体粗略完成：%@",
                viewModel.overallEstimatedCompletionText
            ))
            Text(viewModel.overallEstimateFactorsText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var ocrReview: some View {
        DisclosureGroup("图片字幕 OCR 原文校对（建议先检查低置信度内容）") {
            VStack(alignment: .leading, spacing: 8) {
                Text("可以修改正文；ID 和时间轴必须保持不变。保存后再复制本份给翻译工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $viewModel.manualSourceReviewText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 170)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Spacer()
                    Button("保存本份 OCR 校对") { viewModel.saveManualSourceCorrection() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 8)
        }
    }

    private func sessionHeader(_ session: ManualTranslationSession) -> some View {
        HStack {
            Label(
                AppInterfaceLanguage.localizedFormat(
                    "已完成 %d/%d 份 · 共 %d 条",
                    session.completedChunkCount,
                    session.totalChunkCount,
                    session.sourceDocument.cues.count
                ),
                systemImage: session.isComplete ? "checkmark.circle.fill" : "square.stack.3d.up"
            )
            .foregroundStyle(session.isComplete ? Color.green : Color.primary)
            Spacer()
            Button("重新拆分") { viewModel.restartManualTranslation() }
                .buttonStyle(.bordered)
        }
    }

    private func chunkPicker(_ session: ManualTranslationSession) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(0..<session.totalChunkCount, id: \.self) { index in
                    Button {
                        viewModel.moveManualChunk(to: index)
                    } label: {
                        HStack(spacing: 4) {
                            if session.completedChunkIndexes.contains(index) {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(AppInterfaceLanguage.localizedFormat("第 %d 份", index + 1))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(index == session.currentChunkIndex ? Color.accentColor : Color.secondary.opacity(0.55))
                }
            }
        }
    }

    private func currentChunkContent(_ chunk: ManualTranslationChunk, session: ManualTranslationSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            chunkNavigation(chunk, session: session)
            copyPanel
            pastePanel
        }
    }

    private func chunkNavigation(_ chunk: ManualTranslationChunk, session: ManualTranslationSession) -> some View {
        HStack {
            Text(AppInterfaceLanguage.localizedFormat(
                "第 %d/%d 份",
                chunk.index + 1,
                session.totalChunkCount
            ))
            .font(.headline)
            Text(AppInterfaceLanguage.localizedFormat(
                "ID %d–%d · %d 条",
                chunk.cues.first?.id ?? 0,
                chunk.cues.last?.id ?? 0,
                chunk.cues.count
            ))
                .foregroundStyle(.secondary)
            Spacer()
            Button("上一份") { viewModel.moveManualChunk(to: max(0, chunk.index - 1)) }
                .disabled(chunk.index == 0)
            Button("下一份") { viewModel.moveManualChunk(to: min(session.totalChunkCount - 1, chunk.index + 1)) }
                .disabled(chunk.index + 1 >= session.totalChunkCount)
        }
    }

    private var copyPanel: some View {
        GroupBox("复制给翻译工具的文本") {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView {
                    Text(viewModel.manualCopyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 190)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Text("包含翻译要求和本份完整 SRT；不会包含其他分段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("复制本份文本") { viewModel.copyManualChunk() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var pastePanel: some View {
        GroupBox("粘贴翻译后的 SRT") {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $viewModel.manualPastedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 220)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: viewModel.manualPastedText) { _, _ in
                        viewModel.manualPastedTextDidChange()
                    }
                pasteActions
            }
        }
    }

    private var pasteActions: some View {
        HStack {
            Button("从剪贴板粘贴") { viewModel.pasteManualTranslation() }
            Button(viewModel.isCheckingManualFormat ? "AI 正在检查…" : "AI 复核格式（可选）") {
                viewModel.checkCurrentManualChunkWithAI()
            }
            .disabled(viewModel.codexStatus != .loggedIn || viewModel.manualPastedText.isEmpty || viewModel.isCheckingManualFormat)
            if viewModel.codexStatus != .loggedIn {
                Text("无需连接 Codex；本地已校验 ID、时间轴和数量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("校验并保存本份") { viewModel.saveCurrentManualChunk() }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.manualPastedText.isEmpty)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        if !viewModel.manualStatusMessage.isEmpty {
            Label(
                viewModel.manualStatusMessage,
                systemImage: viewModel.manualStatusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle"
            )
            .font(.callout)
            .foregroundStyle(viewModel.manualStatusIsError ? Color.red : Color.secondary)
            .textSelection(.enabled)
        }
    }

    private var completionActions: some View {
        HStack {
            Label("所有分段均已通过本地格式校验，可以合并。", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
            Spacer()
            Button(viewModel.deliveryMode == .sidecarSRT ? "合并并生成 SRT" : "合并并重新封装") {
                viewModel.requestManualFinalization()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
