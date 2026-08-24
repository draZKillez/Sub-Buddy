import AppKit
import Foundation
import MKVSubtitleCore
#if canImport(Translation)
import Translation
#endif

enum TranslationWorkflowMode: String, CaseIterable, Identifiable {
    case automatic
    case appleLocal
    case manual

    var id: String { rawValue }
    var displayName: String {
        let key: String
        switch self {
        case .automatic: key = "Codex 自动翻译"
        case .appleLocal: key = "Apple 本地翻译"
        case .manual: key = "手动分段翻译"
        }
        return AppInterfaceLanguage.localized(key)
    }
}

enum AppleLocalTranslationStatus: Equatable {
    case checking
    case available(downloadRequired: Bool)
    case unsupportedOS
    case unsupportedLanguagePair

    var isReady: Bool {
        if case .available = self { return true }
        return false
    }

    var displayName: String {
        let key: String
        switch self {
        case .checking:
            key = "正在检查系统语言支持…"
        case let .available(downloadRequired):
            key = downloadRequired
                ? "完全在本机处理；首次使用时 macOS 会询问是否下载语言包"
                : "语言包已安装，可完全离线翻译"
        case .unsupportedOS:
            key = "需要 macOS 15 或更高版本"
        case .unsupportedLanguagePair:
            key = "当前 macOS 不支持所选语言组合"
        }
        return AppInterfaceLanguage.localized(key)
    }
}

enum BatchExistingFilePolicy: String, CaseIterable, Identifiable {
    case skip
    case overwrite
    var id: String { rawValue }
    var displayName: String {
        AppInterfaceLanguage.localized(self == .skip ? "跳过已有输出" : "覆盖已有输出")
    }
}

private struct ManualCopyTextCacheKey: Equatable {
    let inputPath: String?
    let trackIndex: Int?
    let chunkSize: Int
    let totalChunkCount: Int
    let currentChunkIndex: Int
    let originalTitle: String
    let targetTitle: String
    let year: Int?
    let sourceLanguage: SubtitleLanguage
    let targetLanguage: SubtitleLanguage
}

@MainActor
final class AppViewModel: ObservableObject {
    private static let shortTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
    private static let completionTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @Published var selectedFile: URL?
    @Published var mediaInfo: MediaInfo?
    @Published var selectedTrackIndex: Int?
    @Published var selectedAudioTrackIndex: Int?
    @Published var movie = MovieInfo(originalTitle: "")
    @Published var codexStatus: CodexConnectionStatus = .cliMissing
    @Published var isInspecting = false
    @Published var isWorking = false
    @Published var isLoggingIn = false
    @Published var isResolvingChineseTitle = false
    @Published var progress = PipelineProgress(phase: .extracting, completedChunks: 0, totalChunks: 0)
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var estimatedRemaining: EstimatedDurationRange?
    @Published var jobStartedAt: Date?
    @Published var jobCompletedAt: Date?
    @Published var errorMessage: String? {
        didSet {
            if errorMessage == nil { retryableWorkflowErrorMessage = nil }
        }
    }
    @Published var outputURL: URL?
    @Published var subtitleOutputMode: SubtitleOutputMode = .pureChinese
    @Published var sourceLanguage: SubtitleLanguage = .english
    @Published var targetLanguage: SubtitleLanguage = .simplifiedChinese
    @Published var deliveryMode: DeliveryMode = .sidecarSRT
    @Published var translationChunkSize = 500
    @Published var codexModel: CodexModel = .luna
    @Published var workflowMode: TranslationWorkflowMode = .automatic
    @Published var appleLocalTranslationStatus: AppleLocalTranslationStatus = .checking
    @Published var manualSession: ManualTranslationSession?
    @Published var manualPastedText = ""
    @Published var manualSourceReviewText = ""
    @Published var manualStatusMessage = ""
    @Published var manualStatusIsError = false
    @Published var manualAIResult: ManualAIFormatCheckResult?
    @Published var isCheckingManualFormat = false
    @Published var completedOutputMode: SubtitleOutputMode?
    @Published var completedDeliveryMode: DeliveryMode?
    @Published var showOverwriteConfirmation = false
    @Published var showManualOverwriteConfirmation = false
    @Published var showFFmpegInstallConfirmation = false
    @Published var showHomebrewRequired = false
    @Published var isInstallingFFmpeg = false
    @Published var ffmpegInstallLog = ""
    @Published var showMKVToolNixInstallConfirmation = false
    @Published var isInstallingMKVToolNix = false
    @Published var mkvToolNixInstallLog = ""
    @Published var selectedFolder: URL?
    @Published var batchJobs: [BatchJob] = []
    @Published var isScanningFolder = false
    @Published var isBatchProcessing = false
    @Published var batchExistingFilePolicy: BatchExistingFilePolicy = .skip
    @Published var whisperModel: WhisperModel
    @Published var downloadingWhisperModel: WhisperModel?
    @Published var whisperDownloadProgress = 0.0
    @Published var whisperStatusMessage = ""
    @Published var speechRecognitionError: String?
    @Published var isSpeechRecognizing = false
    @Published var speechRecognitionProgress = SpeechRecognitionProgress(
        phase: .extractingAudio,
        fraction: 0,
        detail: AppInterfaceLanguage.localized("等待开始")
    )
    @Published var speechOutputURL: URL?
    @Published var showSpeechOverwriteConfirmation = false

    @Published private(set) var tools: ToolPaths
    private let locator: ToolLocating
    private var inspector: MKVInspector
    private var bridge: CodexBridge
    private let manualSessionStore = ManualSessionStore()
    private let batchQueueStore = BatchQueueStore()
    private var translationTask: Task<Void, Never>?
    private var timingTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var folderScanTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var translationGeneration = UUID()
    private var batchQueueGeneration = 0
    private var batchPersistenceRevision: UInt64 = 0
    private var manualAICheckID: UUID?
    private var manualAICheckTask: Task<Void, Never>?
    private var manualSaveID: UUID?
    private var manualSaveTask: Task<Void, Never>?
    private var manualCopyTextCacheKey: ManualCopyTextCacheKey?
    private var cachedManualCopyText = ""
    private var retryableWorkflowErrorMessage: String?
    private var timingEstimator = JobTimingEstimator()
    private let whisperModelStore: WhisperModelStore
    private var whisperDownloadTask: Task<Void, Never>?
    private var speechRecognitionTask: Task<Void, Never>?
    private var speechRecognitionGeneration = UUID()

    init(locator: ToolLocating = ToolLocator(), whisperModelStore: WhisperModelStore = WhisperModelStore()) {
        self.locator = locator
        self.whisperModelStore = whisperModelStore
        let storedModel = UserDefaults.standard.string(forKey: "selectedWhisperModel")
            .flatMap(WhisperModel.init(rawValue:))
        whisperModel = storedModel ?? .recommended
        let paths = locator.locate()
        tools = paths
        inspector = MKVInspector(ffprobeURL: paths.ffprobe)
        bridge = CodexBridge(codexURL: paths.codex, model: CodexModel.luna.rawValue)
        Task { await refreshCodexStatus() }
        Task { await refreshAppleTranslationAvailability() }
        Task { await restoreBatchQueue() }
    }

    var selectedTrack: SubtitleTrack? {
        mediaInfo?.subtitleTracks.first { $0.streamIndex == selectedTrackIndex }
    }

    var selectedAudioTrack: AudioTrack? {
        mediaInfo?.audioTracks.first { $0.streamIndex == selectedAudioTrackIndex }
    }

    var whisperModelState: WhisperModelState {
        whisperModelStore.state(for: whisperModel)
    }

    var isMediaBusy: Bool { isWorking || isSpeechRecognizing }

    var defaultSpeechOutputURL: URL? {
        guard let selectedFile else { return nil }
        let basename = selectedFile.deletingPathExtension().lastPathComponent
        return selectedFile.deletingLastPathComponent().appendingPathComponent("\(basename).en.srt")
    }

    var speechOutputPathText: String {
        speechOutputURL?.path ?? defaultSpeechOutputURL?.path ?? AppInterfaceLanguage.localized("选择 MKV 后自动生成")
    }

    var ffmpegReady: Bool {
        tools.ffmpeg != nil && tools.ffprobe != nil
    }

    var mkvExtractReady: Bool {
        tools.mkvextract != nil
    }

    var usesBundledFFmpeg: Bool {
        guard let resourceURL = Bundle.main.resourceURL,
              let ffmpeg = tools.ffmpeg,
              let ffprobe = tools.ffprobe else { return false }
        let toolsDirectory = resourceURL.appendingPathComponent("Tools", isDirectory: true).standardizedFileURL.path
        return ffmpeg.standardizedFileURL.path.hasPrefix(toolsDirectory) &&
            ffprobe.standardizedFileURL.path.hasPrefix(toolsDirectory)
    }

    var outputPathText: String {
        outputURL?.path ?? defaultOutputURL?.path ?? AppInterfaceLanguage.localized("选择 MKV 后自动生成")
    }

    var defaultOutputURL: URL? {
        guard let selectedFile else { return nil }
        let basename = selectedFile.deletingPathExtension().lastPathComponent
        let directory = selectedFile.deletingLastPathComponent()
        switch deliveryMode {
        case .sidecarSRT:
            return directory.appendingPathComponent(
                "\(basename)\(subtitleOutputMode.sidecarFileSuffix(targetLanguage: targetLanguage)).srt"
            )
        case .muxMKV:
            return directory.appendingPathComponent(
                "\(basename)\(subtitleOutputMode.muxFileSuffix(targetLanguage: targetLanguage)).mkv"
            )
        }
    }

    var temporarySubtitleFileName: String {
        if deliveryMode == .sidecarSRT {
            return defaultOutputURL?.lastPathComponent ?? AppInterfaceLanguage.localized("与视频同名.srt")
        }
        return subtitleOutputMode == .bilingual
            ? "\(targetLanguage.outputCode)-bilingual.srt"
            : "\(targetLanguage.outputCode).srt"
    }

    var chunkSizeIsValid: Bool {
        (1...1_000).contains(translationChunkSize)
    }

    var languagePairIsValid: Bool { sourceLanguage != targetLanguage }

    var selectedTranslationProviderIsReady: Bool {
        switch workflowMode {
        case .automatic:
            return codexStatus == .loggedIn
        case .appleLocal:
            return appleLocalTranslationStatus.isReady
        case .manual:
            return true
        }
    }

    var canRetryCurrentWorkflow: Bool {
        guard let errorMessage else { return false }
        return retryableWorkflowErrorMessage == errorMessage
    }

    var enabledBatchJobCount: Int { batchJobs.filter(\.isEnabled).count }
    var completedBatchJobCount: Int { batchJobs.filter { $0.status == .completed || $0.status == .skipped }.count }
    var failedBatchJobCount: Int { batchJobs.filter { $0.status == .failed }.count }
    var batchProgressFraction: Double {
        let enabledJobs = batchJobs.filter(\.isEnabled)
        guard !enabledJobs.isEmpty else { return 0 }
        return enabledJobs.reduce(0) { $0 + $1.progressFraction } / Double(enabledJobs.count)
    }

    var overwriteExplanation: String {
        AppInterfaceLanguage.localized(
            deliveryMode == .sidecarSRT
                ? "只会覆盖已有的同名 SRT，原始 MKV 不会被修改。"
                : "只会覆盖已有的翻译版 MKV，原始 MKV 永远不会被覆盖。"
        )
    }

    var elapsedTimeText: String { Self.durationText(elapsedSeconds) }

    var estimatedRemainingText: String {
        guard let estimatedRemaining else {
            return AppInterfaceLanguage.localized("正在收集速度，完成首个有效进度后显示")
        }
        return AppInterfaceLanguage.localizedFormat(
            "约 %@–%@",
            Self.durationText(estimatedRemaining.lowerBound),
            Self.durationText(estimatedRemaining.upperBound)
        )
    }

    var estimatedCompletionText: String {
        guard let estimatedRemaining else { return AppInterfaceLanguage.localized("计算中") }
        let now = Date()
        let lower = Self.shortTimeFormatter.string(from: now.addingTimeInterval(estimatedRemaining.lowerBound))
        let upper = Self.shortTimeFormatter.string(from: now.addingTimeInterval(estimatedRemaining.upperBound))
        return lower == upper ? lower : "\(lower)–\(upper)"
    }

    var completionTimeText: String? {
        guard let jobCompletedAt else { return nil }
        return Self.completionTimeFormatter.string(from: jobCompletedAt)
    }

    func outputSettingsDidChange() {
        guard !isWorking else { return }
        outputURL = nil
        completedOutputMode = nil
        completedDeliveryMode = nil
    }

    func languageSettingsDidChange() {
        guard !isWorking else { return }
        outputSettingsDidChange()
        resetManualSession()
        abandonJobTiming()
        if let mediaInfo {
            selectedTrackIndex = preferredTrack(in: mediaInfo)?.streamIndex
        }
        Task { await refreshAppleTranslationAvailability() }
    }

    func interfaceLanguageDidChange() {
        // Status messages are snapshots. Clear idle snapshots so text from the
        // previously selected interface language cannot remain on screen.
        guard !isWorking, !isSpeechRecognizing, downloadingWhisperModel == nil else {
            objectWillChange.send()
            return
        }
        errorMessage = nil
        speechRecognitionError = nil
        manualStatusMessage = ""
        whisperStatusMessage = ""
        ffmpegInstallLog = ""
        mkvToolNixInstallLog = ""
        speechRecognitionProgress = .init(
            phase: .extractingAudio,
            fraction: 0,
            detail: AppInterfaceLanguage.localized("等待开始")
        )
        objectWillChange.send()
    }

    func trackTitle(for mode: SubtitleOutputMode) -> String {
        mode.trackTitle(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    func workflowModeDidChange() {
        errorMessage = nil
        outputURL = nil
        if manualSession != nil {
            resetManualSession()
            abandonJobTiming()
        }
        if workflowMode == .appleLocal {
            Task { await refreshAppleTranslationAvailability() }
        }
    }

    func refreshAppleTranslationAvailability() async {
        guard languagePairIsValid else {
            appleLocalTranslationStatus = .unsupportedLanguagePair
            return
        }
#if canImport(Translation)
        guard #available(macOS 15.0, *) else {
            appleLocalTranslationStatus = .unsupportedOS
            return
        }
        appleLocalTranslationStatus = .checking
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: Locale.Language(identifier: sourceLanguage.rawValue),
            to: Locale.Language(identifier: targetLanguage.rawValue)
        )
        switch status {
        case .installed:
            appleLocalTranslationStatus = .available(downloadRequired: false)
        case .supported:
            appleLocalTranslationStatus = .available(downloadRequired: true)
        case .unsupported:
            appleLocalTranslationStatus = .unsupportedLanguagePair
        @unknown default:
            appleLocalTranslationStatus = .unsupportedLanguagePair
        }
#else
        appleLocalTranslationStatus = .unsupportedOS
#endif
    }

    func codexModelDidChange() {
        guard !isWorking else { return }
        bridge = CodexBridge(codexURL: tools.codex, model: codexModel.rawValue)
        errorMessage = nil
        if codexStatus == .modelUnavailable || codexStatus == .quotaOrServiceUnavailable {
            Task { await refreshCodexStatus() }
        }
    }

    func selectSubtitleTrack(_ index: Int) {
        guard !isMediaBusy else { return }
        selectedTrackIndex = index
        resetManualSession()
        abandonJobTiming()
    }

    func selectAudioTrack(_ index: Int) {
        guard !isMediaBusy else { return }
        selectedAudioTrackIndex = index
        speechOutputURL = nil
        speechRecognitionError = nil
    }

    func whisperModelDidChange() {
        guard downloadingWhisperModel == nil, !isSpeechRecognizing else { return }
        UserDefaults.standard.set(whisperModel.rawValue, forKey: "selectedWhisperModel")
        whisperStatusMessage = ""
        speechRecognitionError = nil
    }

    func loadFile(_ url: URL, preservingBatch: Bool = false) {
        guard !isMediaBusy else { return }
        batchQueueGeneration += 1
        inspectionTask?.cancel()
        folderScanTask?.cancel()
        isScanningFolder = false
        let generation = UUID()
        selectionGeneration = generation
        translationGeneration = UUID()
        if !preservingBatch {
            let hadBatchSelection = !batchJobs.isEmpty || selectedFolder != nil
            batchJobs = []
            selectedFolder = nil
            if hadBatchSelection {
                persistBatchQueueClear()
            }
        }
        errorMessage = nil
        outputURL = nil
        completedOutputMode = nil
        completedDeliveryMode = nil
        resetManualSession()
        abandonJobTiming()
        isInspecting = true
        selectedFile = url
        mediaInfo = nil
        selectedTrackIndex = nil
        selectedAudioTrackIndex = nil
        speechOutputURL = nil
        speechRecognitionError = nil
        inspectionTask = Task {
            defer {
                if selectionGeneration == generation { isInspecting = false }
            }
            do {
                let info = try await inspector.inspect(url)
                try Task.checkCancellation()
                guard selectionGeneration == generation, selectedFile == url else { return }
                mediaInfo = info
                selectedTrackIndex = preferredTrack(in: info)?.streamIndex
                selectedAudioTrackIndex = preferredAudioTrack(in: info)?.streamIndex
                movie = MovieTitleResolver().resolve(fileURL: url, containerTitle: info.containerTitle)
            } catch is CancellationError {
                return
            } catch {
                guard selectionGeneration == generation else { return }
                mediaInfo = nil
                selectedTrackIndex = nil
                selectedAudioTrackIndex = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadFolder(_ url: URL) {
        guard !isMediaBusy, !isScanningFolder, !isBatchProcessing else { return }
        batchQueueGeneration += 1
        inspectionTask?.cancel()
        folderScanTask?.cancel()
        let generation = UUID()
        selectionGeneration = generation
        translationGeneration = UUID()
        isInspecting = false
        selectedFolder = url
        selectedFile = nil
        mediaInfo = nil
        selectedTrackIndex = nil
        selectedAudioTrackIndex = nil
        outputURL = nil
        completedOutputMode = nil
        completedDeliveryMode = nil
        errorMessage = nil
        resetManualSession()
        abandonJobTiming()
        isScanningFolder = true
        folderScanTask = Task {
            defer {
                if selectionGeneration == generation { isScanningFolder = false }
            }
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    try MKVFolderScanner().scan(url)
                }.value
                try Task.checkCancellation()
                guard selectionGeneration == generation else { return }
                guard !urls.isEmpty else {
                    batchJobs = []
                    throw AppError.invalidMedia("所选文件夹及其子文件夹中没有找到 MKV 文件。")
                }
                batchJobs = urls.map { BatchJob(inputPath: $0.path) }
                await persistBatchQueueNow()
                let jobIDs = batchJobs.map(\.id)
                for (offset, jobID) in jobIDs.enumerated() {
                    try Task.checkCancellation()
                    guard selectionGeneration == generation,
                          batchJobs.indices.contains(offset),
                          batchJobs[offset].id == jobID else { return }
                    let index = offset
                    batchJobs[index].status = .inspecting
                    batchJobs[index].detail = "正在读取字幕轨道"
                    do {
                        let input = batchJobs[index].inputURL
                        let info = try await inspector.inspect(input)
                        try Task.checkCancellation()
                        guard selectionGeneration == generation,
                              batchJobs.indices.contains(index),
                              batchJobs[index].id == jobID else { return }
                        let currentIndex = index
                        if let track = preferredTrack(in: info) {
                            batchJobs[currentIndex].status = .ready
                            batchJobs[currentIndex].detail = "轨道 #\(track.streamIndex) · \(track.codec) · \(track.language)"
                        } else {
                            batchJobs[currentIndex].status = .failed
                            batchJobs[currentIndex].isEnabled = false
                            batchJobs[currentIndex].detail = "没有可处理的文本、PGS 或 VobSub 字幕"
                        }
                    } catch is CancellationError {
                        return
                    } catch {
                        guard selectionGeneration == generation,
                              batchJobs.indices.contains(index),
                              batchJobs[index].id == jobID else { return }
                        let currentIndex = index
                        batchJobs[currentIndex].status = .failed
                        batchJobs[currentIndex].isEnabled = false
                        batchJobs[currentIndex].detail = error.localizedDescription
                    }
                    if (offset + 1).isMultiple(of: 5) { await persistBatchQueueNow() }
                }
                guard selectionGeneration == generation else { return }
                await persistBatchQueueNow()
                if let first = batchJobs.first(where: { $0.isEnabled && $0.status == .ready }) {
                    loadBatchJob(first.id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard selectionGeneration == generation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleBatchJob(_ id: UUID) {
        guard !isWorking, !isBatchProcessing, !isScanningFolder, !isInspecting,
              let index = batchJobs.firstIndex(where: { $0.id == id }) else { return }
        batchJobs[index].isEnabled.toggle()
        persistBatchQueueSnapshot()
    }

    func loadBatchJob(_ id: UUID) {
        guard !isWorking, !isBatchProcessing, !isInspecting,
              let job = batchJobs.first(where: { $0.id == id }) else { return }
        loadFile(job.inputURL, preservingBatch: true)
    }

    func clearBatchQueue() {
        guard !isWorking, !isBatchProcessing, !isScanningFolder, !isInspecting else { return }
        batchQueueGeneration += 1
        batchJobs = []
        selectedFolder = nil
        persistBatchQueueClear()
    }

    func startBatchProcessing() {
        guard workflowMode != .manual,
              !isBatchProcessing,
              !isWorking,
              !isScanningFolder,
              !isInspecting,
              chunkSizeIsValid,
              languagePairIsValid else { return }
        guard ffmpegReady else {
            errorMessage = "媒体工具尚未就绪，请先重新检测 FFmpeg/ffprobe。"
            return
        }
        let provider: any TranslationProvider
        do {
            provider = try selectedTranslationProvider()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let runnable = batchJobs.indices.filter {
            batchJobs[$0].isEnabled && [.ready, .failed, .queued].contains(batchJobs[$0].status)
        }
        guard !runnable.isEmpty else {
            errorMessage = "队列中没有等待处理的文件。"
            return
        }

        isBatchProcessing = true
        isWorking = true
        errorMessage = nil
        outputURL = nil
        beginJobTiming()
        let requestedOutputMode = subtitleOutputMode
        let requestedDeliveryMode = deliveryMode
        let requestedSourceLanguage = sourceLanguage
        let requestedTargetLanguage = targetLanguage
        let overwrite = batchExistingFilePolicy == .overwrite
        let chunkSize = translationChunkSize
        let workflowGeneration = UUID()
        translationGeneration = workflowGeneration
        translationTask = Task {
            defer {
                isBatchProcessing = false
                isWorking = false
                translationTask = nil
                finishJobTiming()
            }
            for index in runnable {
                guard !Task.isCancelled else { break }
                let jobID = batchJobs[index].id
                let input = batchJobs[index].inputURL
                batchJobs[index].status = .processing
                batchJobs[index].startedAt = Date()
                batchJobs[index].detail = "正在重新确认媒体信息"
                batchJobs[index].progressFraction = 0
                await persistBatchQueueNow()
                do {
                    let info = try await inspector.inspect(input)
                    guard let track = preferredTrack(in: info) else {
                        throw AppError.unsupportedSubtitle("没有可处理的文本、PGS 或 VobSub 字幕。")
                    }
                    let movieContext = MovieTitleResolver().resolve(fileURL: input, containerTitle: info.containerTitle)
                    let output = outputURL(
                        for: input,
                        deliveryMode: requestedDeliveryMode,
                        outputMode: requestedOutputMode,
                        targetLanguage: requestedTargetLanguage
                    )
                    if FileManager.default.fileExists(atPath: output.path), !overwrite {
                        batchJobs[index].status = .skipped
                        batchJobs[index].detail = "输出已存在，按队列设置跳过"
                        batchJobs[index].progressFraction = 1
                        batchJobs[index].completedAt = Date()
                        await persistBatchQueueNow()
                        continue
                    }
                    let pipeline = TranslationPipeline(
                        ffmpeg: FFmpegService(ffmpegURL: tools.ffmpeg, mkvextractURL: tools.mkvextract, bitmapSubtitleDecoderURL: tools.bitmapSubtitleDecoder),
                        provider: provider,
                        chunker: TranslationChunker(configuration: .init(
                            targetCoreCount: chunkSize,
                            maximumCoreCount: chunkSize,
                            maximumCoreCharacters: max(80_000, chunkSize * 300),
                            contextCount: 50
                        ))
                    )
                    let result = try await pipeline.run(
                        input: input,
                        track: track,
                        movie: movieContext,
                        output: output,
                        existingSubtitleCount: info.subtitleTracks.count,
                        durationSeconds: info.durationSeconds,
                        outputMode: requestedOutputMode,
                        deliveryMode: requestedDeliveryMode,
                        sourceLanguage: requestedSourceLanguage,
                        targetLanguage: requestedTargetLanguage,
                        overwrite: overwrite
                    ) { [weak self] value in
                        Task { @MainActor in
                            guard let self,
                                  self.translationGeneration == workflowGeneration,
                                  self.batchJobs.indices.contains(index),
                                  self.batchJobs[index].id == jobID,
                                  self.batchJobs[index].status == .processing else { return }
                            self.setProgress(value, allowCompletion: false)
                            self.batchJobs[index].detail = value.detail ?? value.phase.rawValue
                            self.batchJobs[index].progressFraction = self.overallFraction(for: value)
                        }
                    }
                    batchJobs[index].status = .completed
                    batchJobs[index].detail = "已完成 · \(result.lastPathComponent)"
                    batchJobs[index].progressFraction = 1
                    batchJobs[index].outputPath = result.path
                    batchJobs[index].completedAt = Date()
                    outputURL = result
                } catch is CancellationError {
                    batchJobs[index].status = .ready
                    batchJobs[index].detail = "已取消，可继续处理"
                    await persistBatchQueueNow()
                    break
                } catch let appError as AppError where appError == .cancelled {
                    batchJobs[index].status = .ready
                    batchJobs[index].detail = "已取消，可继续处理"
                    await persistBatchQueueNow()
                    break
                } catch let appError as AppError where Self.isBlockingCodexError(appError) {
                    updateCodexStatus(for: appError)
                    batchJobs[index].status = .ready
                    batchJobs[index].detail = appError.localizedDescription
                    await persistBatchQueueNow()
                    errorMessage = appError.localizedDescription
                    break
                } catch {
                    batchJobs[index].status = .failed
                    batchJobs[index].detail = error.localizedDescription
                    batchJobs[index].completedAt = Date()
                }
                await persistBatchQueueNow()
            }
            completedOutputMode = requestedOutputMode
            completedDeliveryMode = requestedDeliveryMode
        }
    }

    func downloadSelectedWhisperModel() {
        guard downloadingWhisperModel == nil, !isSpeechRecognizing else { return }
        let requestedModel = whisperModel
        downloadingWhisperModel = requestedModel
        whisperDownloadProgress = 0
        whisperStatusMessage = AppInterfaceLanguage.localizedFormat(
            "正在下载 %@（%@）…",
            requestedModel.displayName,
            requestedModel.downloadSizeText
        )
        speechRecognitionError = nil
        whisperDownloadTask = Task {
            defer {
                if downloadingWhisperModel == requestedModel {
                    downloadingWhisperModel = nil
                    whisperDownloadTask = nil
                }
            }
            do {
                _ = try await whisperModelStore.download(requestedModel) { [weak self] fraction in
                    Task { @MainActor in
                        guard self?.downloadingWhisperModel == requestedModel else { return }
                        self?.whisperDownloadProgress = fraction
                    }
                }
                guard !Task.isCancelled else { return }
                whisperDownloadProgress = 1
                whisperStatusMessage = AppInterfaceLanguage.localizedFormat(
                    "%@ 已下载并通过完整性校验。",
                    requestedModel.displayName
                )
            } catch is CancellationError {
                whisperStatusMessage = AppInterfaceLanguage.localized("已取消模型下载。")
            } catch {
                speechRecognitionError = error.localizedDescription
                whisperStatusMessage = AppInterfaceLanguage.localized("模型尚未安装，可重新下载。")
            }
        }
    }

    func cancelWhisperModelDownload() {
        whisperDownloadTask?.cancel()
    }

    func deleteSelectedWhisperModel() {
        guard downloadingWhisperModel == nil, !isSpeechRecognizing else { return }
        do {
            try whisperModelStore.delete(whisperModel)
            whisperStatusMessage = AppInterfaceLanguage.localizedFormat(
                "已删除 %@，需要时可重新下载。",
                whisperModel.displayName
            )
            speechRecognitionError = nil
        } catch {
            speechRecognitionError = AppInterfaceLanguage.localizedFormat(
                "无法删除 Whisper 模型：%@",
                error.localizedDescription
            )
        }
    }

    func requestSpeechRecognition() {
        guard let output = defaultSpeechOutputURL else { return }
        if FileManager.default.fileExists(atPath: output.path) {
            showSpeechOverwriteConfirmation = true
        } else {
            startSpeechRecognition(overwrite: false)
        }
    }

    func startSpeechRecognition(overwrite: Bool) {
        guard !isMediaBusy, !isInspecting,
              let input = selectedFile,
              let mediaInfo,
              let audioTrack = selectedAudioTrack,
              let output = defaultSpeechOutputURL else { return }
        guard ffmpegReady else {
            speechRecognitionError = "媒体工具尚未就绪，请先重新检测 FFmpeg/ffprobe。"
            return
        }
        guard whisperModelState == .installed else {
            speechRecognitionError = whisperModelState == .damaged
                ? "当前模型文件不完整，请删除后重新下载。"
                : "请先下载所选 Whisper 模型。"
            return
        }
        if FileManager.default.fileExists(atPath: output.path), !overwrite {
            showSpeechOverwriteConfirmation = true
            return
        }

        let generation = UUID()
        speechRecognitionGeneration = generation
        isSpeechRecognizing = true
        speechRecognitionError = nil
        speechOutputURL = nil
        speechRecognitionProgress = .init(
            phase: .extractingAudio,
            fraction: 0,
            detail: AppInterfaceLanguage.localized("正在提取英语音轨")
        )
        let modelURL = whisperModelStore.fileURL(for: whisperModel)
        let model = whisperModel
        let prompt = [
            movie.originalTitle.isEmpty ? nil : "Title: \(movie.originalTitle)",
            movie.year.map { "Year: \($0)" },
            "Transcribe the English dialogue accurately. Preserve names and natural sentence boundaries."
        ].compactMap { $0 }.joined(separator: "\n")

        speechRecognitionTask = Task {
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("AIViewingCompanion-Speech-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: temporaryRoot)
                if speechRecognitionGeneration == generation {
                    isSpeechRecognizing = false
                    speechRecognitionTask = nil
                }
            }
            do {
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                let pcm = temporaryRoot.appendingPathComponent("audio.f32")
                let service = FFmpegService(ffmpegURL: tools.ffmpeg)
                try await service.extractAudioForSpeechRecognition(
                    input: input,
                    track: audioTrack,
                    output: pcm,
                    durationSeconds: mediaInfo.durationSeconds
                ) { [weak self] fraction in
                    Task { @MainActor in
                        guard self?.speechRecognitionGeneration == generation,
                              self?.isSpeechRecognizing == true else { return }
                        self?.speechRecognitionProgress = .init(
                            phase: .extractingAudio,
                            fraction: fraction * 0.12,
                            detail: AppInterfaceLanguage.localizedFormat(
                                "正在从音轨 #%d 提取 16 kHz 单声道音频",
                                audioTrack.streamIndex
                            )
                        )
                    }
                }
                try Task.checkCancellation()
                let document = try await WhisperTranscriber().transcribe(
                    rawPCMURL: pcm,
                    modelURL: modelURL,
                    prompt: prompt
                ) { [weak self] value in
                    Task { @MainActor in
                        guard self?.speechRecognitionGeneration == generation,
                              self?.isSpeechRecognizing == true else { return }
                        let overall = 0.12 + value.fraction * 0.86
                        self?.speechRecognitionProgress = .init(
                            phase: value.phase,
                            fraction: overall,
                            detail: value.detail
                        )
                    }
                }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: output.path), !overwrite {
                    throw AppError.outputExists(output)
                }
                speechRecognitionProgress = .init(
                    phase: .writing,
                    fraction: 0.99,
                    detail: AppInterfaceLanguage.localizedFormat(
                        "正在写入 %d 条英文字幕",
                        document.cues.count
                    )
                )
                try SubtitleWriter().write(document, to: output, overwrite: overwrite)
                speechOutputURL = output
                speechRecognitionProgress = .init(
                    phase: .writing,
                    fraction: 1,
                    detail: AppInterfaceLanguage.localizedFormat(
                        "已使用 %@ 生成 %d 条英文字幕",
                        model.displayName,
                        document.cues.count
                    )
                )
            } catch is CancellationError {
                guard speechRecognitionGeneration == generation else { return }
                speechRecognitionError = nil
                speechRecognitionProgress = .init(
                    phase: .recognizing,
                    fraction: 0,
                    detail: AppInterfaceLanguage.localized("语音识别已取消")
                )
            } catch {
                guard speechRecognitionGeneration == generation else { return }
                speechRecognitionError = error.localizedDescription
            }
        }
    }

    func cancelSpeechRecognition() {
        speechRecognitionTask?.cancel()
    }

    func revealSpeechOutput() {
        guard let speechOutputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([speechOutputURL])
    }

    func refreshCodexStatus() async {
        codexStatus = await bridge.connectionStatus()
    }

    func refreshEnvironment() async {
        let paths = locator.locate()
        tools = paths
        inspector = MKVInspector(ffprobeURL: paths.ffprobe)
        bridge = CodexBridge(codexURL: paths.codex, model: codexModel.rawValue)
        codexStatus = await bridge.connectionStatus()
    }

    func requestFFmpegInstallation() {
        errorMessage = nil
        ffmpegInstallLog = ""
        guard tools.homebrew != nil else {
            showHomebrewRequired = true
            return
        }
        showFFmpegInstallConfirmation = true
    }

    func installFFmpeg() {
        guard !isInstallingFFmpeg else { return }
        guard let homebrew = tools.homebrew else {
            showHomebrewRequired = true
            return
        }
        isInstallingFFmpeg = true
        ffmpegInstallLog = "Homebrew 正在下载并安装 FFmpeg，请稍候…"
        errorMessage = nil
        Task {
            defer { isInstallingFFmpeg = false }
            do {
                let log = try await HomebrewFFmpegInstaller(homebrewURL: homebrew).install()
                ffmpegInstallLog = log
                let paths = locator.locate()
                tools = paths
                inspector = MKVInspector(ffprobeURL: paths.ffprobe)
                guard ffmpegReady else {
                    throw AppError.toolMissing(
                        name: "FFmpeg",
                        guidance: "Homebrew 已结束安装，但应用仍未找到 ffmpeg/ffprobe。请重新打开应用或检查 Homebrew 安装路径。"
                    )
                }
                ffmpegInstallLog = "FFmpeg 安装完成，已自动检测到 ffmpeg 和 ffprobe。"
                if let selectedFile, mediaInfo == nil { loadFile(selectedFile) }
            } catch {
                errorMessage = error.localizedDescription
                ffmpegInstallLog = "安装未完成。请查看错误提示后重试。"
            }
        }
    }

    func requestMKVToolNixInstallation() {
        errorMessage = nil
        mkvToolNixInstallLog = ""
        guard tools.homebrew != nil else {
            showHomebrewRequired = true
            return
        }
        showMKVToolNixInstallConfirmation = true
    }

    func installMKVToolNix() {
        guard !isInstallingMKVToolNix else { return }
        guard let homebrew = tools.homebrew else {
            showHomebrewRequired = true
            return
        }
        isInstallingMKVToolNix = true
        mkvToolNixInstallLog = "Homebrew 正在安装 MKVToolNix，请稍候…"
        errorMessage = nil
        Task {
            defer { isInstallingMKVToolNix = false }
            do {
                let log = try await HomebrewMKVToolNixInstaller(homebrewURL: homebrew).install()
                mkvToolNixInstallLog = log
                let paths = locator.locate()
                tools = paths
                guard mkvExtractReady else {
                    throw AppError.toolMissing(
                        name: "mkvextract",
                        guidance: "Homebrew 已结束安装，但应用仍未找到 mkvextract。请重新打开应用或检查 Homebrew 安装路径。"
                    )
                }
                mkvToolNixInstallLog = "MKVToolNix 安装完成，后续将优先使用 mkvextract 快速提取。"
            } catch {
                errorMessage = error.localizedDescription
                mkvToolNixInstallLog = "安装未完成。未安装时仍可使用 FFmpeg 提取。"
            }
        }
    }

    func openHomebrewInstructions() {
        let command = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        if let url = URL(string: "https://brew.sh/zh-cn/") {
            NSWorkspace.shared.open(url)
        }
    }

    func connectChatGPT() {
        guard !isLoggingIn else { return }
        isLoggingIn = true
        errorMessage = nil
        Task {
            defer { isLoggingIn = false }
            do {
                try await bridge.login()
                await refreshCodexStatus()
            } catch {
                errorMessage = error.localizedDescription
                await refreshCodexStatus()
            }
        }
    }

    func suggestChineseTitles() {
        guard codexStatus == .loggedIn, !movie.originalTitle.isEmpty, !isResolvingChineseTitle else { return }
        isResolvingChineseTitle = true
        errorMessage = nil
        let originalTitle = movie.originalTitle
        let year = movie.year
        Task {
            defer { isResolvingChineseTitle = false }
            do {
                let candidates = try await CodexMovieMetadataProvider(bridge: bridge)
                    .chineseTitleCandidates(originalTitle: originalTitle, year: year)
                guard movie.originalTitle == originalTitle, movie.year == year else { return }
                movie.chineseTitleCandidates = candidates
                if candidates.isEmpty {
                    errorMessage = "无法可靠确定中文片名；该字段是可选项，可以留空继续翻译。"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    var manualCopyText: String {
        guard let manualSession else { return "" }
        let key = ManualCopyTextCacheKey(
            inputPath: selectedFile?.path,
            trackIndex: selectedTrackIndex,
            chunkSize: manualSession.chunkSize,
            totalChunkCount: manualSession.totalChunkCount,
            currentChunkIndex: manualSession.currentChunkIndex,
            originalTitle: movie.originalTitle,
            targetTitle: movie.chineseTitle,
            year: movie.year,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        if manualCopyTextCacheKey == key { return cachedManualCopyText }
        let text = (try? manualSession.copyText(
            movie: movie,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )) ?? ""
        manualCopyTextCacheKey = key
        cachedManualCopyText = text
        return text
    }

    func prepareManualTranslation() {
        guard !isWorking, !isInspecting else { return }
        guard let input = selectedFile,
              let mediaInfo,
              let track = selectedTrack else { return }
        guard ffmpegReady else {
            errorMessage = "媒体工具尚未就绪，请先重新检测 FFmpeg/ffprobe。"
            return
        }
        guard chunkSizeIsValid else {
            errorMessage = "每份字幕数量必须在 1 到 1000 之间。"
            return
        }
        guard languagePairIsValid else {
            errorMessage = "原文语言和目标语言不能相同。"
            return
        }
        guard track.isProcessable else {
            errorMessage = "手动模式支持文本字幕、PGS 与 VobSub 本地 OCR。"
            return
        }

        isWorking = true
        beginJobTiming()
        updateCurrentBatchJob(status: .processing, detail: "手动模式正在提取字幕", progress: 0.02)
        errorMessage = nil
        manualStatusMessage = ""
        outputURL = nil
        let chunkSize = translationChunkSize
        let service = FFmpegService(ffmpegURL: tools.ffmpeg, mkvextractURL: tools.mkvextract, bitmapSubtitleDecoderURL: tools.bitmapSubtitleDecoder)
        let workflowGeneration = UUID()
        translationGeneration = workflowGeneration
        translationTask = Task {
            defer {
                isWorking = false
                translationTask = nil
            }
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MKVSubtitleTranslator-Manual-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temporaryRoot) }
                let detail = "手动模式 · 轨道 #\(track.streamIndex) · \(track.codec) · \(track.language)"
                setProgress(PipelineProgress(
                    phase: .extracting,
                    completedChunks: 0,
                    totalChunks: 0,
                    phaseFraction: 0,
                    detail: detail
                ))
                let document: SubtitleDocument
                var ocrWarning: String?
                if track.isText {
                    let format = try FFmpegService.subtitleFormat(for: track.codec)
                    let source = temporaryRoot.appendingPathComponent("source.\(FFmpegService.fileExtension(for: format))")
                    try await service.extractSubtitle(
                        input: input,
                        track: track,
                        output: source,
                        durationSeconds: mediaInfo.durationSeconds
                    ) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self,
                                  self.translationGeneration == workflowGeneration else { return }
                            self.setProgress(PipelineProgress(
                                phase: .extracting, completedChunks: 0, totalChunks: 0,
                                phaseFraction: fraction, detail: detail
                            ))
                        }
                    }
                    let parseTask = Task.detached(priority: .userInitiated) {
                        try SubtitleParser().parse(contentsOf: source, format: format)
                    }
                    document = try await withTaskCancellationHandler {
                        try await parseTask.value
                    } onCancel: {
                        parseTask.cancel()
                    }
                    try Task.checkCancellation()
                } else {
                    let source = temporaryRoot.appendingPathComponent(track.isPGS ? "source.sup" : "source.mkvbm")
                    let extractionProgress: @Sendable (Double) -> Void = { [weak self] fraction in
                        Task { @MainActor in
                            guard let self,
                                  self.translationGeneration == workflowGeneration else { return }
                            self.setProgress(PipelineProgress(
                                phase: .extracting, completedChunks: 0, totalChunks: 0,
                                phaseFraction: fraction, detail: detail + (track.isPGS ? " · PGS" : " · VobSub 位图解码")
                            ))
                        }
                    }
                    if track.isPGS {
                        try await service.extractPGSSubtitle(
                            input: input, track: track, output: source,
                            durationSeconds: mediaInfo.durationSeconds, progress: extractionProgress
                        )
                    } else {
                        try await service.decodeVobSubSubtitle(
                            input: input, track: track, output: source, progress: extractionProgress
                        )
                    }
                    let ocrProgress: @Sendable (Int, Int) -> Void = { [weak self] completed, total in
                        Task { @MainActor in
                            guard let self,
                                  self.translationGeneration == workflowGeneration else { return }
                            self.setProgress(PipelineProgress(
                                phase: .ocr, completedChunks: 0, totalChunks: 0,
                                phaseFraction: total > 0 ? Double(completed) / Double(total) : 0,
                                detail: AppInterfaceLanguage.localized("Apple Vision 本地 OCR · 完成后可在手动文本中校对"),
                                completedItems: completed, totalItems: total
                            ))
                        }
                    }
                    let ocr = if track.isPGS {
                        try await LocalPGSOCRService().recognize(
                            supURL: source, language: sourceLanguage.recognitionLanguage, progress: ocrProgress
                        )
                    } else {
                        try await LocalPGSOCRService().recognize(
                            bitmapArchiveURL: source, language: sourceLanguage.recognitionLanguage, progress: ocrProgress
                        )
                    }
                    document = ocr.document
                    if !ocr.lowConfidenceCueIDs.isEmpty {
                        ocrWarning = AppInterfaceLanguage.localizedFormat(
                            "OCR 有 %d 条低置信度内容，请在复制翻译前留意校对。",
                            ocr.lowConfidenceCueIDs.count
                        )
                    }
                }
                let freshSession = ManualTranslationSession(document: document, chunkSize: chunkSize)
                let savedSession = try await manualSessionStore.load(
                    input: input,
                    trackIndex: track.streamIndex,
                    chunkSize: chunkSize,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                let didRestore = savedSession.map {
                    Self.sameCueStructure($0.sourceDocument.cues, freshSession.sourceDocument.cues)
                } ?? false
                let session = didRestore ? savedSession! : freshSession
                invalidateManualCopyTextCache()
                manualSession = session
                manualPastedText = (try? session.existingTranslationText()) ?? ""
                manualSourceReviewText = (try? session.currentSourceText()) ?? ""
                manualAIResult = nil
                manualStatusIsError = false
                manualStatusMessage = ocrWarning ?? (didRestore
                    ? AppInterfaceLanguage.localizedFormat(
                        "已恢复保存进度：完成 %d/%d 份。",
                        session.completedChunkCount,
                        session.totalChunkCount
                    )
                    : AppInterfaceLanguage.localizedFormat(
                        "已拆分为 %d 份，共 %d 条字幕。",
                        session.totalChunkCount,
                        session.sourceDocument.cues.count
                    ))
                updateCurrentBatchJob(
                    status: .processing,
                    detail: "手动翻译完成 \(session.completedChunkCount)/\(session.totalChunkCount) 份",
                    progress: 0.20 + 0.70 * Double(session.completedChunkCount) / Double(max(1, session.totalChunkCount))
                )
            } catch is CancellationError {
                manualStatusIsError = false
                manualStatusMessage = AppInterfaceLanguage.localized("字幕提取已取消，可以重试。")
                updateCurrentBatchJob(status: .ready, detail: "已取消，可继续处理", progress: 0)
                finishJobTiming()
            } catch {
                let message = error.localizedDescription
                errorMessage = message
                retryableWorkflowErrorMessage = message
                updateCurrentBatchJob(status: .failed, detail: message, progress: 0)
                finishJobTiming()
            }
        }
    }

    func copyManualChunk() {
        guard !manualCopyText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(manualCopyText, forType: .string)
        manualStatusIsError = false
        manualStatusMessage = AppInterfaceLanguage.localized("本份字幕和翻译要求已复制，可以粘贴到任意 AI。")
    }

    func pasteManualTranslation() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        invalidateManualAICheck()
        manualPastedText = text
        manualAIResult = nil
        manualStatusMessage = AppInterfaceLanguage.localized("已从剪贴板粘贴，请校验并保存本份。")
        manualStatusIsError = false
    }

    func saveCurrentManualChunk() {
        guard var session = manualSession else { return }
        invalidateManualAICheck()
        do {
            let savedIndex = session.currentChunkIndex
            try session.applyCurrentTranslation(manualPastedText)
            manualSession = session
            manualPastedText = (try? session.existingTranslationText()) ?? ""
            manualSourceReviewText = (try? session.currentSourceText()) ?? ""
            manualAIResult = nil
            manualStatusIsError = false
            let savedMessage = AppInterfaceLanguage.localizedFormat(
                "第 %d 份格式正确并已保存。已完成 %d/%d 份。",
                savedIndex + 1,
                session.completedChunkCount,
                session.totalChunkCount
            )
            manualStatusMessage = AppInterfaceLanguage.localizedFormat(
                "格式正确，正在保存第 %d 份进度…",
                savedIndex + 1
            )
            updateCurrentBatchJob(
                status: .processing,
                detail: "手动翻译完成 \(session.completedChunkCount)/\(session.totalChunkCount) 份",
                progress: 0.20 + 0.70 * Double(session.completedChunkCount) / Double(max(1, session.totalChunkCount))
            )
            if let input = selectedFile, let track = selectedTrack {
                let sourceLanguage = sourceLanguage
                let targetLanguage = targetLanguage
                enqueueManualSave(
                    session,
                    input: input,
                    trackIndex: track.streamIndex,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    successMessage: savedMessage
                )
            }
        } catch {
            manualStatusIsError = true
            manualStatusMessage = error.localizedDescription
        }
    }

    func saveManualSourceCorrection() {
        guard var session = manualSession else { return }
        do {
            try session.applyCurrentSourceCorrection(manualSourceReviewText)
            invalidateManualCopyTextCache()
            manualSession = session
            manualPastedText = ""
            manualSourceReviewText = (try? session.currentSourceText()) ?? ""
            manualStatusIsError = false
            let savedMessage = AppInterfaceLanguage.localized("当前分段的 OCR 原文已校对保存；请重新复制本份翻译文本。")
            manualStatusMessage = AppInterfaceLanguage.localized("OCR 校对格式正确，正在保存进度…")
            if let input = selectedFile, let track = selectedTrack {
                let sourceLanguage = sourceLanguage
                let targetLanguage = targetLanguage
                enqueueManualSave(
                    session,
                    input: input,
                    trackIndex: track.streamIndex,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    successMessage: savedMessage
                )
            }
        } catch {
            manualStatusIsError = true
            manualStatusMessage = error.localizedDescription
        }
    }

    func moveManualChunk(to index: Int) {
        invalidateManualAICheck()
        guard var session = manualSession else { return }
        session.move(to: index)
        manualSession = session
        manualPastedText = (try? session.existingTranslationText()) ?? ""
        manualSourceReviewText = (try? session.currentSourceText()) ?? ""
        manualAIResult = nil
        manualStatusMessage = ""
    }

    func restartManualTranslation() {
        guard let input = selectedFile, let track = selectedTrack else { return }
        let chunkSize = translationChunkSize
        Task {
            _ = await manualSaveTask?.result
            try? await manualSessionStore.clear(
                input: input,
                trackIndex: track.streamIndex,
                chunkSize: chunkSize,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            resetManualSession()
            prepareManualTranslation()
        }
    }

    func checkCurrentManualChunkWithAI() {
        guard !isCheckingManualFormat,
              codexStatus == .loggedIn,
              let chunk = manualSession?.currentChunk else { return }
        do {
            _ = try ManualSRTValidator().validate(manualPastedText, expectedCues: chunk.cues)
        } catch {
            manualStatusIsError = true
            manualStatusMessage = AppInterfaceLanguage.localizedFormat(
                "本地格式校验未通过，无需调用 AI：%@",
                error.localizedDescription
            )
            return
        }
        isCheckingManualFormat = true
        let checkID = UUID()
        manualAICheckID = checkID
        manualAIResult = nil
        manualStatusMessage = AppInterfaceLanguage.localized("AI 仅在复核 SRT 格式，不会检查或修改翻译内容…")
        let text = manualPastedText
        let chunkIndex = manualSession?.currentChunkIndex
        manualAICheckTask = Task {
            defer {
                if manualAICheckID == checkID {
                    isCheckingManualFormat = false
                    manualAICheckID = nil
                    manualAICheckTask = nil
                }
            }
            do {
                let result = try await CodexManualFormatChecker(bridge: bridge).check(srt: text, expectedCues: chunk.cues)
                guard manualAICheckID == checkID,
                      manualSession?.currentChunkIndex == chunkIndex,
                      manualPastedText == text else { return }
                manualAIResult = result
                manualStatusIsError = !result.valid
                manualStatusMessage = result.valid
                    ? AppInterfaceLanguage.localized("AI 格式复核通过；未检查翻译内容。")
                    : AppInterfaceLanguage.localizedFormat(
                        "AI 发现格式问题：%@",
                        result.issues.joined(separator: AppInterfaceLanguage.localized("；"))
                    )
            } catch {
                guard manualAICheckID == checkID else { return }
                manualStatusIsError = true
                manualStatusMessage = error.localizedDescription
            }
        }
    }

    func manualPastedTextDidChange() {
        let discardedRunningCheck = manualAICheckID != nil || isCheckingManualFormat
        invalidateManualAICheck()
        if discardedRunningCheck {
            manualStatusIsError = false
            manualStatusMessage = AppInterfaceLanguage.localized("字幕内容已更改，先前的 AI 格式检查已取消。")
        }
    }

    func requestManualFinalization() {
        guard manualSession?.isComplete == true, let output = defaultOutputURL else { return }
        if FileManager.default.fileExists(atPath: output.path) {
            showManualOverwriteConfirmation = true
        } else {
            finalizeManualTranslation(overwrite: false)
        }
    }

    func finalizeManualTranslation(overwrite: Bool) {
        guard let input = selectedFile,
              let mediaInfo,
              let output = defaultOutputURL,
              let session = manualSession else { return }
        let requestedOutputMode = subtitleOutputMode
        let requestedDeliveryMode = deliveryMode
        let requestedSourceLanguage = sourceLanguage
        let requestedTargetLanguage = targetLanguage
        let document: SubtitleDocument
        do {
            document = try session.mergedDocument(outputMode: requestedOutputMode)
        } catch {
            manualStatusIsError = true
            manualStatusMessage = error.localizedDescription
            return
        }
        isWorking = true
        if jobStartedAt == nil { beginJobTiming() }
        errorMessage = nil
        outputURL = nil
        let workflowGeneration = UUID()
        translationGeneration = workflowGeneration
        translationTask = Task {
            defer {
                isWorking = false
                translationTask = nil
            }
            let temporaryRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("MKVSubtitleTranslator-ManualOutput-\(UUID().uuidString)", isDirectory: true)
            do {
                setProgress(PipelineProgress(
                    phase: .writingSubtitle,
                    completedChunks: session.totalChunkCount,
                    totalChunks: session.totalChunkCount,
                    detail: "合并 \(session.totalChunkCount) 份 · \(output.lastPathComponent)",
                    completedItems: document.cues.count,
                    totalItems: document.cues.count
                ))
                if requestedDeliveryMode == .sidecarSRT {
                    if FileManager.default.fileExists(atPath: output.path) && !overwrite {
                        throw AppError.outputExists(output)
                    }
                    try SubtitleWriter().write(document, to: output, overwrite: overwrite)
                } else {
                    try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
                    let subtitle = temporaryRoot.appendingPathComponent("manual-\(requestedTargetLanguage.outputCode).srt")
                    try SubtitleWriter().write(document, to: subtitle)
                    let requestedTrackTitle = requestedOutputMode == .bilingual
                        ? "\(requestedTargetLanguage.displayName) + \(requestedSourceLanguage.displayName)"
                        : requestedTargetLanguage.displayName
                    let detail = "复制原有轨道，并新增“\(requestedTrackTitle)”"
                    try await FFmpegService(ffmpegURL: tools.ffmpeg).mux(
                        input: input,
                        chineseSubtitle: subtitle,
                        output: output,
                        existingSubtitleCount: mediaInfo.subtitleTracks.count,
                        trackTitle: requestedTrackTitle,
                        languageCode: requestedTargetLanguage.iso6392Code,
                        overwrite: overwrite,
                        durationSeconds: mediaInfo.durationSeconds
                    ) { [weak self] fraction in
                        Task { @MainActor in
                            guard let self,
                                  self.translationGeneration == workflowGeneration else { return }
                            self.setProgress(PipelineProgress(
                                phase: .muxing,
                                completedChunks: session.totalChunkCount,
                                totalChunks: session.totalChunkCount,
                                phaseFraction: fraction,
                                detail: detail,
                                completedItems: document.cues.count,
                                totalItems: document.cues.count
                            ))
                        }
                    }
                }
                outputURL = output
                completedOutputMode = requestedOutputMode
                completedDeliveryMode = requestedDeliveryMode
                manualStatusIsError = false
                manualStatusMessage = AppInterfaceLanguage.localized("所有分段已合并完成。")
                updateCurrentBatchJob(
                    status: .completed,
                    detail: "已完成 · \(output.lastPathComponent)",
                    progress: 1,
                    output: output
                )
                setProgress(PipelineProgress(
                    phase: .completed,
                    completedChunks: session.totalChunkCount,
                    totalChunks: session.totalChunkCount,
                    phaseFraction: 1,
                    detail: output.lastPathComponent,
                    completedItems: document.cues.count,
                    totalItems: document.cues.count
                ))
                if let track = selectedTrack {
                    _ = await manualSaveTask?.result
                    try? await manualSessionStore.clear(
                        input: input,
                        trackIndex: track.streamIndex,
                        chunkSize: session.chunkSize,
                        sourceLanguage: requestedSourceLanguage,
                        targetLanguage: requestedTargetLanguage
                    )
                }
            } catch is CancellationError {
                manualStatusIsError = false
                manualStatusMessage = AppInterfaceLanguage.localized("字幕生成已取消；已完成的手动分段仍然保留。")
                updateCurrentBatchJob(status: .ready, detail: "已取消，可继续处理", progress: 0.9)
                finishJobTiming()
            } catch {
                errorMessage = error.localizedDescription
                updateCurrentBatchJob(status: .failed, detail: error.localizedDescription, progress: 0.9)
                finishJobTiming()
            }
        }
    }

    private func resetManualSession() {
        invalidateManualAICheck()
        invalidateManualCopyTextCache()
        manualSaveID = nil
        manualSession = nil
        manualPastedText = ""
        manualSourceReviewText = ""
        manualStatusMessage = ""
        manualStatusIsError = false
        manualAIResult = nil
    }

    func requestTranslation() {
        guard let output = defaultOutputURL else { return }
        if FileManager.default.fileExists(atPath: output.path) {
            showOverwriteConfirmation = true
        } else {
            startTranslation(overwrite: false)
        }
    }

    func startTranslation(overwrite: Bool) {
        guard !isWorking, !isInspecting else { return }
        guard let input = selectedFile,
              let mediaInfo,
              let track = selectedTrack,
              let output = defaultOutputURL else { return }
        guard ffmpegReady else {
            errorMessage = "媒体工具尚未就绪，请先重新检测 FFmpeg/ffprobe。"
            return
        }
        guard languagePairIsValid else {
            errorMessage = "原文语言和目标语言不能相同。"
            return
        }
        guard track.isProcessable else {
            errorMessage = "当前仅支持文本字幕、PGS 与 VobSub 本地 OCR。"
            return
        }
        guard chunkSizeIsValid else {
            errorMessage = "每块字幕数量必须在 1 到 1000 之间。"
            return
        }

        let provider: any TranslationProvider
        do {
            provider = try selectedTranslationProvider()
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        isWorking = true
        beginJobTiming()
        errorMessage = nil
        outputURL = nil
        completedOutputMode = nil
        completedDeliveryMode = nil
        let chunkSize = translationChunkSize
        let pipeline = TranslationPipeline(
            ffmpeg: FFmpegService(ffmpegURL: tools.ffmpeg, mkvextractURL: tools.mkvextract, bitmapSubtitleDecoderURL: tools.bitmapSubtitleDecoder),
            provider: provider,
            chunker: TranslationChunker(configuration: .init(
                targetCoreCount: chunkSize,
                maximumCoreCount: chunkSize,
                maximumCoreCharacters: max(80_000, chunkSize * 300),
                contextCount: 50
            ))
        )
        let movieContext = movie
        let requestedOutputMode = subtitleOutputMode
        let requestedDeliveryMode = deliveryMode
        let requestedSourceLanguage = sourceLanguage
        let requestedTargetLanguage = targetLanguage
        let workflowGeneration = UUID()
        translationGeneration = workflowGeneration
        translationTask = Task {
            defer {
                isWorking = false
                translationTask = nil
            }
            do {
                let result = try await pipeline.run(
                    input: input,
                    track: track,
                    movie: movieContext,
                    output: output,
                    existingSubtitleCount: mediaInfo.subtitleTracks.count,
                    durationSeconds: mediaInfo.durationSeconds,
                    outputMode: requestedOutputMode,
                    deliveryMode: requestedDeliveryMode,
                    sourceLanguage: requestedSourceLanguage,
                    targetLanguage: requestedTargetLanguage,
                    overwrite: overwrite
                ) { [weak self] progress in
                    Task { @MainActor in
                        guard let self,
                              self.translationGeneration == workflowGeneration else { return }
                        self.setProgress(progress)
                    }
                }
                outputURL = result
                completedOutputMode = requestedOutputMode
                completedDeliveryMode = requestedDeliveryMode
            } catch is CancellationError {
                errorMessage = nil
                retryableWorkflowErrorMessage = nil
                finishJobTiming()
            } catch let appError as AppError where appError == .cancelled {
                errorMessage = nil
                retryableWorkflowErrorMessage = nil
                finishJobTiming()
            } catch {
                let message = error.localizedDescription
                errorMessage = message
                if let appError = error as? AppError, Self.isBlockingCodexError(appError) {
                    retryableWorkflowErrorMessage = nil
                } else {
                    retryableWorkflowErrorMessage = message
                }
                finishJobTiming()
                if case AppError.codexModelUnavailable(_) = error { codexStatus = .modelUnavailable }
                if case AppError.codexQuotaUnavailable = error { codexStatus = .quotaOrServiceUnavailable }
                if case AppError.codexServiceUnavailable = error { codexStatus = .quotaOrServiceUnavailable }
                if case AppError.codexNotLoggedIn = error { codexStatus = .notLoggedIn }
            }
        }
    }

    func cancel() {
        // Invalidate already-enqueued progress callbacks before asking the
        // underlying process/OCR task to stop, so cancelled UI cannot regress.
        translationGeneration = UUID()
        translationTask?.cancel()
    }

    func retryCurrentWorkflow() {
        guard canRetryCurrentWorkflow else { return }
        if workflowMode == .manual {
            if manualSession == nil { prepareManualTranslation() }
        } else {
            requestTranslation()
        }
    }

    private func selectedTranslationProvider() throws -> any TranslationProvider {
        switch workflowMode {
        case .automatic:
            guard codexStatus == .loggedIn else {
                throw codexStatus == .cliMissing
                    ? AppError.toolMissing(
                        name: "Codex CLI",
                        guidance: "请先安装 ChatGPT/Codex，再点击“连接 ChatGPT”。"
                    )
                    : AppError.codexNotLoggedIn
            }
            return CodexTranslationProvider(bridge: bridge)
        case .appleLocal:
            guard appleLocalTranslationStatus.isReady else {
                throw AppError.localTranslationUnavailable(appleLocalTranslationStatus.displayName)
            }
#if canImport(Translation)
            guard #available(macOS 15.0, *) else {
                throw AppError.localTranslationUnavailable("需要 macOS 15 或更高版本。")
            }
            return AppleTranslationRuntime.shared
#else
            throw AppError.localTranslationUnavailable("当前构建未包含 Apple Translation framework。")
#endif
        case .manual:
            throw AppError.localTranslationUnavailable("请选择自动翻译模式，或使用手动分段界面。")
        }
    }

    func revealOutput() {
        guard let outputURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([outputURL])
    }

    private func beginJobTiming() {
        timingTask?.cancel()
        timingEstimator.start()
        jobStartedAt = timingEstimator.startedAt
        jobCompletedAt = nil
        elapsedSeconds = 0
        estimatedRemaining = nil
        timingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                self?.refreshTimingDisplay()
            }
        }
    }

    private func setProgress(_ value: PipelineProgress, allowCompletion: Bool = true) {
        progress = value
        if value.phase == .completed, !allowCompletion {
            refreshTimingDisplay()
            return
        }
        timingEstimator.update(value)
        refreshTimingDisplay()
        if value.phase == .completed {
            timingTask?.cancel()
            timingTask = nil
        }
    }

    private func finishJobTiming() {
        timingEstimator.finish()
        timingTask?.cancel()
        timingTask = nil
        refreshTimingDisplay()
    }

    private func abandonJobTiming() {
        timingTask?.cancel()
        timingTask = nil
        timingEstimator = JobTimingEstimator()
        jobStartedAt = nil
        jobCompletedAt = nil
        elapsedSeconds = 0
        estimatedRemaining = nil
    }

    private func refreshTimingDisplay() {
        elapsedSeconds = timingEstimator.elapsed()
        if isBatchProcessing {
            let finished = batchJobs.filter { $0.status == .completed && $0.startedAt != nil && $0.completedAt != nil }
            let durations = finished.compactMap { job -> TimeInterval? in
                guard let start = job.startedAt, let end = job.completedAt else { return nil }
                return max(1, end.timeIntervalSince(start))
            }
            let remainingUnits = batchJobs.reduce(0.0) { total, job in
                guard job.isEnabled else { return total }
                switch job.status {
                case .completed, .skipped, .failed: return total
                case .processing: return total + max(0, 1 - job.progressFraction)
                default: return total + 1
                }
            }
            if !durations.isEmpty, remainingUnits > 0 {
                let average = durations.reduce(0, +) / Double(durations.count)
                estimatedRemaining = EstimatedDurationRange(
                    lowerBound: average * remainingUnits * 0.65,
                    upperBound: average * remainingUnits * 1.35 + 10
                )
            } else {
                estimatedRemaining = timingEstimator.estimatedRemaining()
            }
        } else {
            estimatedRemaining = timingEstimator.estimatedRemaining()
        }
        jobStartedAt = timingEstimator.startedAt
        jobCompletedAt = timingEstimator.completedAt
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        if hours > 0 { return AppInterfaceLanguage.localizedFormat("%d 小时 %02d 分", hours, minutes) }
        if minutes > 0 { return AppInterfaceLanguage.localizedFormat("%d 分 %02d 秒", minutes, remainder) }
        return AppInterfaceLanguage.localizedFormat("%d 秒", remainder)
    }

    private func preferredTrack(in info: MediaInfo) -> SubtitleTrack? {
        info.subtitleTracks.first(where: { $0.isText && $0.matches(sourceLanguage) })
            ?? info.subtitleTracks.first(where: { $0.supportsLocalOCR && $0.matches(sourceLanguage) })
            ?? info.subtitleTracks.first(where: \.isText)
            ?? info.subtitleTracks.first(where: \.supportsLocalOCR)
    }

    private func preferredAudioTrack(in info: MediaInfo) -> AudioTrack? {
        info.audioTracks.first(where: \.isEnglish)
            ?? info.audioTracks.first(where: \.isDefault)
            ?? info.audioTracks.first
    }

    private func outputURL(
        for input: URL,
        deliveryMode: DeliveryMode,
        outputMode: SubtitleOutputMode,
        targetLanguage: SubtitleLanguage
    ) -> URL {
        let directory = input.deletingLastPathComponent()
        let basename = input.deletingPathExtension().lastPathComponent
        switch deliveryMode {
        case .sidecarSRT:
            return directory.appendingPathComponent(
                "\(basename)\(outputMode.sidecarFileSuffix(targetLanguage: targetLanguage)).srt"
            )
        case .muxMKV:
            return directory.appendingPathComponent(
                "\(basename)\(outputMode.muxFileSuffix(targetLanguage: targetLanguage)).mkv"
            )
        }
    }

    private func overallFraction(for progress: PipelineProgress) -> Double {
        switch progress.phase {
        case .extracting: return 0.05 * (progress.phaseFraction ?? 0)
        case .ocr: return 0.05 + 0.20 * (progress.phaseFraction ?? 0)
        case .translating:
            let fraction = progress.totalItems > 0 ? Double(progress.completedItems) / Double(progress.totalItems) : 0
            return 0.25 + 0.65 * fraction
        case .writingSubtitle: return 0.92
        case .muxing: return 0.92 + 0.08 * (progress.phaseFraction ?? 0)
        case .completed: return 1
        }
    }

    private func restoreBatchQueue() async {
        let expectedGeneration = batchQueueGeneration
        guard let stored = try? await batchQueueStore.load() else { return }
        guard batchQueueGeneration == expectedGeneration, batchJobs.isEmpty, selectedFolder == nil else { return }
        batchJobs = stored.map { job in
            var restored = job
            if restored.status == .processing || restored.status == .inspecting {
                restored.status = .ready
                restored.detail = "上次任务中断，可以继续"
            }
            return restored
        }
    }

    private func persistBatchQueueNow() async {
        batchPersistenceRevision &+= 1
        let revision = batchPersistenceRevision
        let snapshot = batchJobs
        try? await batchQueueStore.save(snapshot, revision: revision)
    }

    private func persistBatchQueueSnapshot() {
        batchPersistenceRevision &+= 1
        let revision = batchPersistenceRevision
        let snapshot = batchJobs
        let store = batchQueueStore
        Task { try? await store.save(snapshot, revision: revision) }
    }

    private func persistBatchQueueClear() {
        batchPersistenceRevision &+= 1
        let revision = batchPersistenceRevision
        let store = batchQueueStore
        Task { try? await store.clear(revision: revision) }
    }

    private func updateCurrentBatchJob(
        status: BatchJobStatus,
        detail: String,
        progress: Double,
        output: URL? = nil
    ) {
        guard let selectedFile,
              let index = batchJobs.firstIndex(where: { $0.inputPath == selectedFile.path }) else { return }
        batchJobs[index].status = status
        batchJobs[index].detail = detail
        batchJobs[index].progressFraction = min(1, max(0, progress))
        if batchJobs[index].startedAt == nil { batchJobs[index].startedAt = jobStartedAt ?? Date() }
        if status == .completed {
            batchJobs[index].completedAt = Date()
            batchJobs[index].outputPath = output?.path
        }
        persistBatchQueueSnapshot()
    }

    private func enqueueManualSave(
        _ session: ManualTranslationSession,
        input: URL,
        trackIndex: Int,
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage,
        successMessage: String
    ) {
        let previous = manualSaveTask
        let store = manualSessionStore
        let saveID = UUID()
        manualSaveID = saveID
        manualSaveTask = Task { [weak self] in
            _ = await previous?.result
            do {
                try await store.save(
                    session,
                    input: input,
                    trackIndex: trackIndex,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                guard let self,
                      self.manualSaveID == saveID,
                      self.selectedFile == input,
                      self.manualSession != nil else { return }
                self.manualStatusIsError = false
                self.manualStatusMessage = successMessage
            } catch {
                guard let self,
                      self.manualSaveID == saveID,
                      self.selectedFile == input,
                      self.manualSession != nil else { return }
                self.manualStatusIsError = true
                self.manualStatusMessage = "进度写入失败：\(error.localizedDescription)"
            }
        }
    }

    private func invalidateManualAICheck() {
        guard manualAICheckID != nil || isCheckingManualFormat else { return }
        manualAICheckTask?.cancel()
        manualAICheckTask = nil
        manualAICheckID = nil
        isCheckingManualFormat = false
        manualAIResult = nil
    }

    private func invalidateManualCopyTextCache() {
        manualCopyTextCacheKey = nil
        cachedManualCopyText = ""
    }

    private static func sameCueStructure(_ first: [SubtitleCue], _ second: [SubtitleCue]) -> Bool {
        guard first.count == second.count else { return false }
        return zip(first, second).allSatisfy { lhs, rhs in
            lhs.id == rhs.id &&
                lhs.startMilliseconds == rhs.startMilliseconds &&
                lhs.endMilliseconds == rhs.endMilliseconds
        }
    }

    private static func isBlockingCodexError(_ error: AppError) -> Bool {
        switch error {
        case .codexNotLoggedIn, .codexModelUnavailable(_), .codexQuotaUnavailable, .codexServiceUnavailable:
            return true
        default:
            return false
        }
    }

    private func updateCodexStatus(for error: AppError) {
        switch error {
        case .codexNotLoggedIn: codexStatus = .notLoggedIn
        case .codexModelUnavailable(_): codexStatus = .modelUnavailable
        case .codexQuotaUnavailable, .codexServiceUnavailable: codexStatus = .quotaOrServiceUnavailable
        default: break
        }
    }
}
