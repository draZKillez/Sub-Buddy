import Foundation
import SwiftUI
import UIKit

@MainActor
final class MobileViewModel: ObservableObject {
    enum WorkPhase: String {
        case idle
        case inspecting = "正在读取 MKV 轨道"
        case extracting = "正在提取字幕"
        case ocr = "正在本机识别 PGS"
        case parsing = "正在整理字幕"
    }

    @Published var sourceName = ""
    @Published var movie = MovieInfo(originalTitle: "")
    @Published var chunkSize = 500
    @Published var rebuildChunkSize = 500
    @Published var outputMode: SubtitleOutputMode = .pureChinese
    @Published var sourceLanguage: SubtitleLanguage = .english
    @Published var targetLanguage: SubtitleLanguage = .simplifiedChinese
    @Published var mediaInfo: MediaInfo?
    @Published var selectedTrackIndex: Int?
    @Published var session: ManualTranslationSession?
    @Published var copyText = ""
    @Published var pastedText = ""
    @Published var sourceReviewText = ""
    @Published var statusMessage = "选择一个 MKV 开始；也可直接导入字幕文件。"
    @Published var isError = false
    @Published var workPhase: WorkPhase = .idle
    @Published var phaseFraction: Double?
    @Published var completedItems = 0
    @Published var totalItems = 0
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var estimatedRemaining: ClosedRange<TimeInterval>?
    @Published var completedAt: Date?
    @Published var lowConfidenceCueIDs: [Int] = []
    @Published var isOCRSource = false
    @Published var exportDocument: SubtitleExportDocument?
    @Published var exportFilename = "字幕_zh.srt"
    @Published var isExporting = false

    private let writer = SubtitleWriter()
    private let validator = ManualSRTValidator()
    private let workspaceStore = MobileWorkspaceStore()
    private let nativeMKV = NativeMKVService()
    private var activeTask: Task<Void, Never>?
    private var operationStartedAt: Date?
    private var clockTask: Task<Void, Never>?
    private var metadataUpdateTask: Task<Void, Never>?
    private var inputURL: URL?
    private var inputAccessGranted = false
    private var sourceFileExtension = ""
    private var operationToken: UUID?
    private var stateGeneration: UInt64 = 0
    private var workspaceRevision: UInt64 = 0
    private var previousIdleTimerDisabled: Bool?

    private static let maximumTextSubtitleBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumSUPBytes: Int64 = 256 * 1_024 * 1_024

    init() {
        let expectedGeneration = stateGeneration
        Task { [weak self] in
            await self?.restoreWorkspace(expectedGeneration: expectedGeneration)
        }
    }

    deinit {
        activeTask?.cancel()
        clockTask?.cancel()
        metadataUpdateTask?.cancel()
        if inputAccessGranted { inputURL?.stopAccessingSecurityScopedResource() }
        if let previousIdleTimerDisabled {
            Task { @MainActor in
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
        }
    }

    var ffmpegVersion: String { nativeMKV.version }
    var isBusy: Bool { workPhase != .idle }
    var hasWorkspace: Bool { session != nil }
    var selectedTrack: SubtitleTrack? {
        guard let selectedTrackIndex else { return nil }
        return mediaInfo?.subtitleTracks.first { $0.streamIndex == selectedTrackIndex }
    }
    var canPrepareSelectedTrack: Bool {
        selectedTrack?.isProcessable == true && !isBusy && chunkSizeIsValid && languagePairIsValid
    }
    var chunkSizeIsValid: Bool { (1...1_000).contains(chunkSize) }
    var rebuildChunkSizeIsValid: Bool { (1...1_000).contains(rebuildChunkSize) }
    var languagePairIsValid: Bool { sourceLanguage != targetLanguage }
    var completedText: String {
        guard let session else { return "" }
        return "已完成 \(session.completedChunkCount)/\(session.totalChunkCount) 份 · 共 \(session.sourceDocument.cues.count) 条"
    }
    var progressFraction: Double {
        if isBusy { return phaseFraction ?? 0 }
        guard let session, session.totalChunkCount > 0 else { return 0 }
        return Double(session.completedChunkCount) / Double(session.totalChunkCount)
    }
    var currentChunkLabel: String {
        guard let session, let chunk = session.currentChunk else { return "" }
        return "第 \(chunk.index + 1)/\(session.totalChunkCount) 份 · ID \(chunk.cues.first?.id ?? 0)–\(chunk.cues.last?.id ?? 0) · \(chunk.cues.count) 条"
    }
    var elapsedText: String { Self.durationText(elapsedSeconds) }
    var etaText: String {
        guard let estimatedRemaining else { return "正在收集速度" }
        return "约 \(Self.durationText(estimatedRemaining.lowerBound))–\(Self.durationText(estimatedRemaining.upperBound))"
    }
    var estimatedCompletionText: String {
        guard let upper = estimatedRemaining?.upperBound else { return "计算中" }
        return Date.now.addingTimeInterval(upper).formatted(date: .omitted, time: .shortened)
    }
    var completionTimeText: String {
        completedAt?.formatted(date: .abbreviated, time: .standard) ?? "—"
    }
    var durationDescription: String {
        guard let duration = mediaInfo?.durationSeconds else { return "未知" }
        return Self.durationText(duration)
    }

    func fileSelectionStarted() {
        setStatus("请在系统“文件”中选择 MKV、SRT、ASS/SSA、WebVTT 或 SUP；大文件会原地读取，不会先复制。", error: false)
    }

    func fileSelectionCancelled() {
        if !isBusy {
            setStatus("已取消选择文件。", error: false)
        }
    }

    func importFile(_ url: URL) {
        let supportedExtensions: Set<String> = ["mkv", "srt", "ass", "ssa", "vtt", "sup"]
        guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
            setStatus("不支持这个文件。请选择 MKV、SRT、ASS/SSA、WebVTT 或 PGS SUP。", error: true)
            return
        }
        guard languagePairIsValid else {
            setStatus("原文语言和目标语言不能相同，请先修改语言。", error: true)
            return
        }
        guard chunkSizeIsValid else {
            setStatus("每份字幕数量必须在 1–1000 之间。", error: true)
            return
        }
        stateGeneration &+= 1
        metadataUpdateTask?.cancel()
        metadataUpdateTask = nil
        activeTask?.cancel()
        let token = beginOperation(.inspecting)
        activeTask = Task { [weak self] in
            await self?.performImport(url, token: token)
        }
    }

    func selectTrack(_ index: Int) {
        guard mediaInfo?.subtitleTracks.contains(where: { $0.streamIndex == index && $0.isProcessable }) == true else { return }
        selectedTrackIndex = index
    }

    func prepareSelectedTrack() {
        guard let inputURL, let track = selectedTrack, canPrepareSelectedTrack else { return }
        activeTask?.cancel()
        let token = beginOperation(.extracting)
        activeTask = Task { [weak self] in
            await self?.extractAndPrepare(input: inputURL, track: track, token: token)
        }
    }

    func cancelCurrentOperation() {
        activeTask?.cancel()
        setStatus("正在安全取消任务；已经保存的手动翻译分段不会丢失。", error: false)
    }

    func copyCurrentPrompt() {
        flushMetadataUpdate()
        guard !copyText.isEmpty else { return }
        UIPasteboard.general.string = copyText
        setStatus("已复制本份提示词和完整 SRT。", error: false)
    }

    func pasteFromClipboard() {
        pastedText = UIPasteboard.general.string ?? ""
    }

    func saveCurrentTranslation() {
        guard var session else { return }
        do {
            try session.applyCurrentTranslation(pastedText, validator: validator)
            self.session = session
            pastedText = (try? session.existingTranslationText()) ?? ""
            refreshCurrentTexts()
            setStatus("本份已通过本地校验并保存。", error: false)
            persistWorkspace()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    func saveOCRCorrection() {
        guard var session else { return }
        do {
            let reviewedIDs = Set(session.currentChunk?.cues.map(\.id) ?? [])
            try session.applyCurrentSourceCorrection(sourceReviewText, validator: validator)
            self.session = session
            lowConfidenceCueIDs.removeAll { reviewedIDs.contains($0) }
            refreshCurrentTexts()
            setStatus("OCR 原文已校正；ID 和时间轴保持不变。", error: false)
            persistWorkspace()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    func moveChunk(_ offset: Int) {
        guard var session else { return }
        session.move(to: max(0, min(session.totalChunkCount - 1, session.currentChunkIndex + offset)))
        self.session = session
        pastedText = (try? session.existingTranslationText()) ?? ""
        refreshCurrentTexts()
        persistWorkspace()
    }

    func metadataDidChange() {
        metadataUpdateTask?.cancel()
        metadataUpdateTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self else { return }
            self.metadataUpdateTask = nil
            self.refreshCurrentTexts()
            self.persistWorkspace()
        }
    }

    func languageSelectionDidChange() {
        metadataUpdateTask?.cancel()
        metadataUpdateTask = nil
        if let tracks = mediaInfo?.subtitleTracks {
            selectedTrackIndex = preferredTrack(in: tracks)?.streamIndex
        }
        refreshCurrentTexts()
        persistWorkspace()
        if !languagePairIsValid {
            setStatus("原文语言和目标语言不能相同。", error: true)
        } else if isError && statusMessage.contains("原文语言和目标语言不能相同") {
            setStatus("语言设置已更新。", error: false)
        }
    }

    func rebuildChunks(using requestedSize: Int) {
        guard let current = session, (1...1_000).contains(requestedSize) else { return }
        chunkSize = requestedSize
        rebuildChunkSize = requestedSize
        session = ManualTranslationSession(document: current.sourceDocument, chunkSize: requestedSize)
        pastedText = ""
        refreshCurrentTexts()
        persistWorkspace()
        setStatus("已按每份 \(requestedSize) 条重新拆分；之前的译文进度已清空。", error: false)
    }

    func exportMergedSRT() {
        guard let session else { return }
        do {
            let document = try session.mergedDocument(outputMode: outputMode)
            exportDocument = SubtitleExportDocument(text: try writer.string(from: document))
            let source = URL(fileURLWithPath: sourceName)
            let base = source.deletingPathExtension().lastPathComponent
            var suffix = outputMode.sidecarFileSuffix(targetLanguage: targetLanguage)
            // A translated subtitle imported directly must never default to the
            // exact source filename. MKV inputs intentionally keep Movie.srt.
            if sourceFileExtension != "mkv", suffix.isEmpty {
                suffix = "_\(targetLanguage.outputCode)"
            }
            exportFilename = base + suffix + ".srt"
            isExporting = true
            persistWorkspace()
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            setStatus("新的 SRT 已导出；原始文件和原字幕没有被修改。", error: false)
        case let .failure(error):
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                setStatus("已取消导出。", error: false)
            } else {
                setStatus("导出失败：\(error.localizedDescription)", error: true)
            }
        }
    }

    func clearWorkspace() {
        stateGeneration &+= 1
        metadataUpdateTask?.cancel()
        metadataUpdateTask = nil
        activeTask?.cancel()
        releaseInputAccess()
        session = nil
        mediaInfo = nil
        selectedTrackIndex = nil
        sourceName = ""
        movie = MovieInfo(originalTitle: "")
        pastedText = ""
        copyText = ""
        sourceReviewText = ""
        lowConfidenceCueIDs = []
        isOCRSource = false
        sourceFileExtension = ""
        completedAt = nil
        invalidateOperation()
        requestWorkspaceClear()
        setStatus("工作区已清空。", error: false)
    }

    private func performImport(_ url: URL, token: UUID) async {
        let candidateAccessGranted = url.startAccessingSecurityScopedResource()
        var transferredCandidateAccess = false
        defer {
            if candidateAccessGranted && !transferredCandidateAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let ext = url.pathExtension.lowercased()
            let candidateMovie = MovieTitleResolver().resolve(fileURL: url, containerTitle: nil)
            if ext == "mkv" {
                let info = try await nativeMKV.inspect(url)
                try Task.checkCancellation()
                guard isCurrentOperation(token) else { return }
                let preferred = preferredTrack(in: info.subtitleTracks)
                if info.subtitleTracks.isEmpty {
                    finishOperation(token: token)
                    setStatus("这个 MKV 中没有检测到字幕轨道；原工作区未被修改。", error: true)
                } else if preferred == nil {
                    finishOperation(token: token)
                    setStatus("检测到 \(info.subtitleTracks.count) 条字幕，但没有可处理的文本或 PGS 轨道；原工作区未被修改。", error: true)
                } else {
                    commitNewInputState(
                        sourceURL: url,
                        movie: MovieTitleResolver().resolve(fileURL: url, containerTitle: info.containerTitle),
                        mediaInfo: info,
                        selectedTrackIndex: preferred?.streamIndex
                    )
                    replaceInputAccess(with: url, accessGranted: candidateAccessGranted)
                    transferredCandidateAccess = true
                    finishOperation(token: token)
                    setStatus("已读取 \(info.subtitleTracks.count) 条字幕轨道。确认所选轨道后开始提取。", error: false)
                }
            } else {
                guard isCurrentOperation(token) else { return }
                workPhase = .parsing
                let result: (document: SubtitleDocument, lowConfidence: [Int], isOCR: Bool)
                if ext == "sup" {
                    try await Self.validateFileSize(
                        at: url,
                        maximumBytes: Self.maximumSUPBytes,
                        kind: "PGS SUP"
                    )
                    let recognized = try await recognizePGS(
                        at: url,
                        language: sourceLanguage.recognitionLanguage,
                        token: token
                    )
                    result = (recognized.document, recognized.lowConfidenceCueIDs, true)
                } else {
                    let format: SubtitleFormat
                    switch ext {
                    case "srt": format = .srt
                    case "ass", "ssa": format = .ass
                    case "vtt": format = .webVTT
                    default:
                        throw AppError.unsupportedSubtitle("请选择 MKV、SRT、ASS/SSA、WebVTT 或 PGS SUP 文件。")
                    }
                    let document = try await Self.parseSubtitleFile(
                        at: url,
                        format: format,
                        maximumBytes: Self.maximumTextSubtitleBytes
                    )
                    result = (document, [], false)
                }
                try Task.checkCancellation()
                guard isCurrentOperation(token) else { return }
                releaseInputAccess()
                commitNewInputState(sourceURL: url, movie: candidateMovie)
                createSession(document: result.document, lowConfidence: result.lowConfidence, isOCR: result.isOCR)
                finishOperation(token: token, completed: true)
            }
        } catch is CancellationError {
            guard isCurrentOperation(token) else { return }
            finishOperation(token: token)
            setStatus("已取消当前任务；原工作区未被修改。", error: false)
        } catch {
            guard isCurrentOperation(token) else { return }
            finishOperation(token: token)
            setStatus("\(error.localizedDescription) 原工作区未被修改。", error: true)
        }
    }

    private func extractAndPrepare(input: URL, track: SubtitleTrack, token: UUID) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MKVSubtitleTranslator-iOS", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent(track.isPGS ? "source.sup" : (track.isVobSub ? "source.mkvbm" : "source.srt"))
            let extractionProgress: @Sendable (Double) -> Void = { [weak self] fraction in
                Task { @MainActor in
                    self?.updateExtractionProgress(fraction, token: token)
                }
            }
            if track.isVobSub {
                try await nativeMKV.decodeBitmapSubtitle(
                    input: input, track: track, output: output, progress: extractionProgress
                )
            } else {
                try await nativeMKV.extract(
                    input: input, track: track, output: output, progress: extractionProgress
                )
            }
            try Task.checkCancellation()
            guard isCurrentOperation(token) else { return }

            if track.supportsLocalOCR {
                let result: PGSOCRResult
                if track.isPGS {
                    try await Self.validateFileSize(
                        at: output, maximumBytes: Self.maximumSUPBytes, kind: "PGS SUP"
                    )
                    result = try await recognizePGS(
                        at: output, language: sourceLanguage.recognitionLanguage, token: token
                    )
                } else {
                    result = try await recognizeBitmapArchive(
                        at: output, language: sourceLanguage.recognitionLanguage, token: token
                    )
                }
                guard isCurrentOperation(token) else { return }
                createSession(document: result.document, lowConfidence: result.lowConfidenceCueIDs, isOCR: true)
            } else {
                workPhase = .parsing
                phaseFraction = nil
                var document = try await Self.parseSubtitleFile(
                    at: output,
                    format: .srt,
                    maximumBytes: Self.maximumTextSubtitleBytes
                )
                guard isCurrentOperation(token) else { return }
                if ["ass", "ssa"].contains(track.codec.lowercased()) {
                    document.cues = document.cues.map { cue in
                        var value = cue
                        value.text = value.text
                            .replacingOccurrences(of: "\\N", with: "\n")
                            .replacingOccurrences(of: "\\n", with: "\n")
                        return value
                    }
                }
                createSession(document: document, lowConfidence: [], isOCR: false)
            }
            releaseInputAccess()
            finishOperation(token: token, completed: true)
        } catch is CancellationError {
            guard isCurrentOperation(token) else { return }
            finishOperation(token: token)
            setStatus("字幕提取已取消。可以更换轨道或重试。", error: false)
        } catch {
            guard isCurrentOperation(token) else { return }
            finishOperation(token: token)
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func recognizePGS(at url: URL, language: String, token: UUID) async throws -> PGSOCRResult {
        guard isCurrentOperation(token) else { throw CancellationError() }
        workPhase = .ocr
        phaseFraction = 0
        completedItems = 0
        totalItems = 0
        setStatus("正在使用 Apple Vision 本机 OCR；字幕图片不会上传。", error: false)
        return try await LocalPGSOCRService().recognize(supURL: url, language: language) { completed, total in
            Task { @MainActor [weak self] in
                self?.updateOCRProgress(completed: completed, total: total, token: token)
            }
        }
    }

    private func recognizeBitmapArchive(at url: URL, language: String, token: UUID) async throws -> PGSOCRResult {
        guard isCurrentOperation(token) else { throw CancellationError() }
        workPhase = .ocr
        phaseFraction = 0
        completedItems = 0
        totalItems = 0
        setStatus("正在使用 Apple Vision 本机 OCR；字幕图片不会上传。", error: false)
        return try await LocalPGSOCRService().recognize(bitmapArchiveURL: url, language: language) { completed, total in
            Task { @MainActor [weak self] in
                self?.updateOCRProgress(completed: completed, total: total, token: token)
            }
        }
    }

    private func createSession(document: SubtitleDocument, lowConfidence: [Int], isOCR: Bool) {
        session = ManualTranslationSession(document: document, chunkSize: chunkSize)
        rebuildChunkSize = chunkSize
        lowConfidenceCueIDs = lowConfidence
        isOCRSource = isOCR
        refreshCurrentTexts()
        let warning = lowConfidence.isEmpty ? "" : "；其中 \(lowConfidence.count) 条 OCR 结果建议人工校对"
        setStatus("已准备 \(document.cues.count) 条字幕，共 \(session?.totalChunkCount ?? 0) 份\(warning)。", error: false)
        persistWorkspace()
    }

    private func preferredTrack(in tracks: [SubtitleTrack]) -> SubtitleTrack? {
        tracks.first { $0.matches(sourceLanguage) && $0.isText }
            ?? tracks.first { $0.matches(sourceLanguage) && $0.supportsLocalOCR }
            ?? tracks.first { $0.isText }
            ?? tracks.first { $0.supportsLocalOCR }
    }

    private func updateExtractionProgress(_ fraction: Double, token: UUID) {
        guard isCurrentOperation(token), workPhase == .extracting else { return }
        phaseFraction = fraction
        updateETA(fraction: fraction)
        statusMessage = "正在提取轨道 #\(selectedTrackIndex ?? 0)：已完成 \(Int((fraction * 100).rounded()))%。大文件请耐心等待。"
    }

    private func updateOCRProgress(completed: Int, total: Int, token: UUID) {
        guard isCurrentOperation(token), workPhase == .ocr else { return }
        completedItems = completed
        totalItems = total
        let fraction = total > 0 ? Double(completed) / Double(total) : 0
        phaseFraction = fraction
        updateETA(fraction: fraction, minimumProgress: min(10, total))
        statusMessage = "正在 OCR：已完成 \(completed)/\(total)，还剩 \(max(0, total - completed)) 条。"
    }

    private func updateETA(fraction: Double, minimumProgress: Int = 0) {
        guard let operationStartedAt, fraction >= 0.03, fraction < 1,
              minimumProgress == 0 || completedItems >= minimumProgress else { return }
        let elapsed = Date.now.timeIntervalSince(operationStartedAt)
        let remaining = elapsed * (1 - fraction) / fraction
        estimatedRemaining = max(1, remaining * 0.8)...max(2, remaining * 1.25 + 3)
    }

    private func refreshCurrentTexts() {
        guard let session else {
            copyText = ""
            sourceReviewText = ""
            return
        }
        copyText = (try? session.copyText(
            movie: movie,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )) ?? ""
        sourceReviewText = (try? session.currentSourceText()) ?? ""
    }

    private func flushMetadataUpdate() {
        guard metadataUpdateTask != nil else { return }
        metadataUpdateTask?.cancel()
        metadataUpdateTask = nil
        refreshCurrentTexts()
        persistWorkspace()
    }

    private func persistWorkspace() {
        guard let session else { return }
        let workspace = MobileWorkspace(
            sourceName: sourceName,
            sourceFileExtension: sourceFileExtension,
            movie: movie,
            session: session,
            outputMode: outputMode,
            lowConfidenceCueIDs: lowConfidenceCueIDs,
            isOCRSource: isOCRSource,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        workspaceRevision &+= 1
        let revision = workspaceRevision
        Task { try? await workspaceStore.save(workspace, revision: revision) }
    }

    private func restoreWorkspace(expectedGeneration: UInt64) async {
        guard let workspace = try? await workspaceStore.load() else { return }
        guard stateGeneration == expectedGeneration, session == nil, mediaInfo == nil, !isBusy else { return }
        sourceName = workspace.sourceName
        sourceFileExtension = workspace.sourceFileExtension
            ?? URL(fileURLWithPath: workspace.sourceName).pathExtension.lowercased()
        movie = workspace.movie
        session = workspace.session
        chunkSize = workspace.session.chunkSize
        rebuildChunkSize = workspace.session.chunkSize
        outputMode = workspace.outputMode
        sourceLanguage = workspace.sourceLanguage ?? .english
        targetLanguage = workspace.targetLanguage ?? .simplifiedChinese
        lowConfidenceCueIDs = workspace.lowConfidenceCueIDs
        isOCRSource = workspace.isOCRSource == true
        pastedText = (try? workspace.session.existingTranslationText()) ?? ""
        refreshCurrentTexts()
        setStatus("已恢复上次手动翻译进度。", error: false)
    }

    private func commitNewInputState(
        sourceURL: URL,
        movie: MovieInfo,
        mediaInfo: MediaInfo? = nil,
        selectedTrackIndex: Int? = nil
    ) {
        sourceName = sourceURL.lastPathComponent
        sourceFileExtension = sourceURL.pathExtension.lowercased()
        self.movie = movie
        self.mediaInfo = mediaInfo
        self.selectedTrackIndex = selectedTrackIndex
        session = nil
        lowConfidenceCueIDs = []
        isOCRSource = false
        pastedText = ""
        copyText = ""
        sourceReviewText = ""
        completedAt = nil
        isError = false
        if mediaInfo != nil {
            requestWorkspaceClear()
        }
    }

    private func requestWorkspaceClear() {
        workspaceRevision &+= 1
        let revision = workspaceRevision
        Task { try? await workspaceStore.clear(revision: revision) }
    }

    private func releaseInputAccess() {
        if inputAccessGranted { inputURL?.stopAccessingSecurityScopedResource() }
        inputAccessGranted = false
        inputURL = nil
    }

    private func replaceInputAccess(with url: URL, accessGranted: Bool) {
        releaseInputAccess()
        inputURL = url
        inputAccessGranted = accessGranted
    }

    private func setStatus(_ message: String, error: Bool) {
        statusMessage = message
        isError = error
    }

    private func beginOperation(_ phase: WorkPhase) -> UUID {
        let token = UUID()
        operationToken = token
        workPhase = phase
        phaseFraction = phase == .inspecting ? nil : 0
        completedItems = 0
        totalItems = 0
        elapsedSeconds = 0
        estimatedRemaining = nil
        completedAt = nil
        operationStartedAt = Date.now
        if previousIdleTimerDisabled == nil {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self,
                      self.operationToken == token,
                      let started = self.operationStartedAt else { continue }
                self.elapsedSeconds = Date.now.timeIntervalSince(started)
            }
        }
        return token
    }

    private func isCurrentOperation(_ token: UUID) -> Bool {
        operationToken == token
    }

    private func finishOperation(token: UUID, completed: Bool = false) {
        guard isCurrentOperation(token) else { return }
        if let started = operationStartedAt { elapsedSeconds = Date.now.timeIntervalSince(started) }
        if completed { completedAt = Date.now }
        operationStartedAt = nil
        operationToken = nil
        clockTask?.cancel()
        clockTask = nil
        restoreIdleTimer()
        workPhase = .idle
        phaseFraction = nil
        estimatedRemaining = nil
    }

    private func invalidateOperation() {
        operationToken = nil
        operationStartedAt = nil
        clockTask?.cancel()
        clockTask = nil
        restoreIdleTimer()
        workPhase = .idle
        phaseFraction = nil
        estimatedRemaining = nil
    }

    private func restoreIdleTimer() {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        self.previousIdleTimerDisabled = nil
    }

    private nonisolated static func parseSubtitleFile(
        at url: URL,
        format: SubtitleFormat,
        maximumBytes: Int64
    ) async throws -> SubtitleDocument {
        try Task.checkCancellation()
        try validateFileSizeSynchronously(at: url, maximumBytes: maximumBytes, kind: "文本字幕")
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try Task.checkCancellation()
        let document = try SubtitleParser().parse(data: data, format: format)
        guard !document.cues.isEmpty else {
            throw AppError.parsingFailed("没有找到有效字幕。")
        }
        return document
    }

    private nonisolated static func validateFileSize(
        at url: URL,
        maximumBytes: Int64,
        kind: String
    ) async throws {
        try Task.checkCancellation()
        try validateFileSizeSynchronously(at: url, maximumBytes: maximumBytes, kind: kind)
    }

    private nonisolated static func validateFileSizeSynchronously(
        at url: URL,
        maximumBytes: Int64,
        kind: String
    ) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        if values.isRegularFile == false {
            throw AppError.parsingFailed("请选择普通文件，而不是文件夹或文件包。")
        }
        if let size = values.fileSize, Int64(size) > maximumBytes {
            let limit = maximumBytes / 1_024 / 1_024
            throw AppError.parsingFailed("\(kind) 文件超过 \(limit) MB 的安全上限。")
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes) 分 \(remainder) 秒" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }
}
