import Foundation

public struct PipelineProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case extracting = "正在提取字幕"
        case ocr = "正在本地识别图片字幕"
        case translating = "正在翻译"
        case writingSubtitle = "正在生成 SRT"
        case muxing = "正在无损封装"
        case completed = "已完成"
    }
    public let phase: Phase
    public let completedChunks: Int
    public let totalChunks: Int
    public let phaseFraction: Double?
    public let detail: String?
    public let completedItems: Int
    public let totalItems: Int

    public init(
        phase: Phase,
        completedChunks: Int,
        totalChunks: Int,
        phaseFraction: Double? = nil,
        detail: String? = nil,
        completedItems: Int = 0,
        totalItems: Int = 0
    ) {
        self.phase = phase
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.phaseFraction = phaseFraction
        self.detail = detail
        self.completedItems = completedItems
        self.totalItems = totalItems
    }
}

public struct SubtitleOutputComposer: Sendable {
    public init() {}

    public func text(
        chinese: String,
        english: String,
        format: SubtitleFormat,
        mode: SubtitleOutputMode
    ) -> String {
        guard mode == .bilingual else { return chinese }
        let separator = format == .ass ? "\\N" : "\n"
        return chinese + separator + english
    }
}

public final class TranslationPipeline: @unchecked Sendable {
    private let ffmpeg: FFmpegService
    private let provider: TranslationProvider
    private let parser: SubtitleParser
    private let writer: SubtitleWriter
    private let chunker: TranslationChunker
    private let ocrService: LocalPGSOCRService
    private let jobStore: JobStore
    private let fileManager: FileManager

    public init(
        ffmpeg: FFmpegService,
        provider: TranslationProvider,
        parser: SubtitleParser = .init(),
        writer: SubtitleWriter = .init(),
        chunker: TranslationChunker = .init(),
        ocrService: LocalPGSOCRService = .init(),
        jobStore: JobStore = JobStore(),
        fileManager: FileManager = .default
    ) {
        self.ffmpeg = ffmpeg
        self.provider = provider
        self.parser = parser
        self.writer = writer
        self.chunker = chunker
        self.ocrService = ocrService
        self.jobStore = jobStore
        self.fileManager = fileManager
    }

    public func run(
        input: URL,
        track: SubtitleTrack,
        movie: MovieInfo,
        output: URL,
        existingSubtitleCount: Int,
        durationSeconds: Double? = nil,
        outputMode: SubtitleOutputMode = .pureChinese,
        deliveryMode: DeliveryMode = .sidecarSRT,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese,
        overwrite: Bool,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> URL {
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MKVSubtitleTranslator", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        do {
            try Task.checkCancellation()
            let trackDetail = "轨道 #\(track.streamIndex) · \(track.codec) · \(track.language)\(track.title.isEmpty ? "" : " · \(track.title)")"
            progress(PipelineProgress(
                phase: .extracting,
                completedChunks: 0,
                totalChunks: 0,
                phaseFraction: 0,
                detail: trackDetail
            ))
            let sourceFormat: SubtitleFormat
            var document: SubtitleDocument
            if track.isText {
                sourceFormat = try FFmpegService.subtitleFormat(for: track.codec)
                let sourceSubtitle = temporaryRoot.appendingPathComponent("source.\(FFmpegService.fileExtension(for: sourceFormat))")
                try await ffmpeg.extractSubtitle(
                    input: input,
                    track: track,
                    output: sourceSubtitle,
                    durationSeconds: durationSeconds
                ) { fraction in
                    progress(PipelineProgress(
                        phase: .extracting,
                        completedChunks: 0,
                        totalChunks: 0,
                        phaseFraction: fraction,
                        detail: trackDetail
                    ))
                }
                document = try parser.parse(contentsOf: sourceSubtitle, format: sourceFormat)
            } else if track.supportsLocalOCR {
                sourceFormat = .srt
                let sourceSubtitle = temporaryRoot.appendingPathComponent(track.isPGS ? "source.sup" : "source.mkvbm")
                if track.isPGS {
                    try await ffmpeg.extractPGSSubtitle(
                        input: input, track: track, output: sourceSubtitle, durationSeconds: durationSeconds
                    ) { fraction in
                        progress(PipelineProgress(
                            phase: .extracting, completedChunks: 0, totalChunks: 0,
                            phaseFraction: fraction, detail: trackDetail + " · PGS"
                        ))
                    }
                } else {
                    try await ffmpeg.decodeVobSubSubtitle(input: input, track: track, output: sourceSubtitle) { fraction in
                        progress(PipelineProgress(
                            phase: .extracting, completedChunks: 0, totalChunks: 0,
                            phaseFraction: fraction, detail: trackDetail + " · VobSub 位图解码"
                        ))
                    }
                }
                progress(PipelineProgress(
                    phase: .ocr,
                    completedChunks: 0,
                    totalChunks: 0,
                    phaseFraction: 0,
                    detail: "Apple Vision 本地 OCR · 不上传图片"
                ))
                let ocrProgress: @Sendable (Int, Int) -> Void = { completed, total in
                    progress(PipelineProgress(
                        phase: .ocr,
                        completedChunks: 0,
                        totalChunks: 0,
                        phaseFraction: total > 0 ? Double(completed) / Double(total) : 0,
                        detail: "Apple Vision 本地 OCR · 低置信度条目会保留提示",
                        completedItems: completed,
                        totalItems: total
                    ))
                }
                let ocrResult = if track.isPGS {
                    try await ocrService.recognize(
                        supURL: sourceSubtitle, language: sourceLanguage.recognitionLanguage, progress: ocrProgress
                    )
                } else {
                    try await ocrService.recognize(
                        bitmapArchiveURL: sourceSubtitle, language: sourceLanguage.recognitionLanguage, progress: ocrProgress
                    )
                }
                document = ocrResult.document
                if !ocrResult.lowConfidenceCueIDs.isEmpty {
                    progress(PipelineProgress(
                        phase: .ocr,
                        completedChunks: 0,
                        totalChunks: 0,
                        phaseFraction: 1,
                        detail: "OCR 完成 · \(ocrResult.lowConfidenceCueIDs.count) 条低置信度内容已标记",
                        completedItems: document.cues.count,
                        totalItems: document.cues.count
                    ))
                }
            } else {
                throw AppError.unsupportedSubtitle("当前仅支持 SRT、ASS、WebVTT、PGS 与 VobSub 本地 OCR。")
            }
            let chunks = chunker.chunks(for: document.cues)

            let translationContext = [
                "prompt-schema-v2",
                movie.originalTitle,
                movie.chineseTitle,
                movie.year.map(String.init) ?? "",
                sourceLanguage.rawValue,
                targetLanguage.rawValue,
                provider.progressLabel
            ].joined(separator: "\u{1F}")
            let freshRecord = TranslationJobRecord(
                inputPath: input.path,
                trackIndex: track.streamIndex,
                sourceLanguageCode: sourceLanguage.rawValue,
                targetLanguageCode: targetLanguage.rawValue,
                translationContext: translationContext
            )
            var record = try await jobStore.load(input: input, trackIndex: track.streamIndex) ?? freshRecord
            if record.inputPath != input.path || record.trackIndex != track.streamIndex ||
                record.sourceLanguageCode != sourceLanguage.rawValue ||
                record.targetLanguageCode != targetLanguage.rawValue ||
                record.translationContext != translationContext {
                record = freshRecord
            }
            record.completedChunkIndexes = Set(chunks.compactMap { chunk in
                guard record.completedChunkIndexes.contains(chunk.index),
                      chunk.core.allSatisfy({ record.translatedItems[$0.id] != nil }) else { return nil }
                return chunk.index
            })
            try await jobStore.save(record, input: input)
            let restoredItemCount = document.cues.reduce(into: 0) { count, cue in
                if record.translatedItems[cue.id] != nil { count += 1 }
            }
            progress(PipelineProgress(
                phase: .translating,
                completedChunks: record.completedChunkIndexes.count,
                totalChunks: chunks.count,
                detail: record.completedChunkIndexes.isEmpty
                    ? "字幕已提取，共 \(document.cues.count) 条；正在准备第 1 块"
                    : "已恢复 \(record.completedChunkIndexes.count)/\(chunks.count) 块保存进度",
                completedItems: restoredItemCount,
                totalItems: document.cues.count
            ))
            let engine = TranslationEngine(provider: provider)

            for chunk in chunks {
                try Task.checkCancellation()
                if record.completedChunkIndexes.contains(chunk.index),
                   chunk.core.allSatisfy({ record.translatedItems[$0.id] != nil }) {
                    progress(translationProgress(
                        chunk: chunk,
                        record: record,
                        allCues: document.cues,
                        totalChunks: chunks.count,
                        detailPrefix: "已从保存进度恢复"
                    ))
                    continue
                }
                progress(translationProgress(
                    chunk: chunk,
                    record: record,
                    allCues: document.cues,
                    totalChunks: chunks.count,
                    detailPrefix: "本块 \(chunk.core.count) 条正一次性提交给 \(provider.progressLabel)"
                ))
                let response = try await engine.translate(
                    chunk: chunk,
                    movie: movie,
                    glossary: record.glossary,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                ) {
                    progress(self.translationProgress(
                        chunk: chunk,
                        record: record,
                        allCues: document.cues,
                        totalChunks: chunks.count,
                        detailPrefix: "正在补齐缺失 ID；若 JSON 被截断将自动分批恢复"
                    ))
                }
                for item in response.items { record.translatedItems[item.id] = item.text }
                record.glossary = mergeGlossary(record.glossary, response.glossaryUpdates)
                record.completedChunkIndexes.insert(chunk.index)
                try await jobStore.save(record, input: input)
                progress(translationProgress(
                    chunk: chunk,
                    record: record,
                    allCues: document.cues,
                    totalChunks: chunks.count,
                    detailPrefix: "本块翻译完成"
                ))
            }

            let composer = SubtitleOutputComposer()
            for index in document.cues.indices {
                guard let translated = record.translatedItems[document.cues[index].id] else {
                    throw AppError.invalidTranslation("字幕 ID \(document.cues[index].id) 尚未翻译。")
                }
                document.cues[index].text = composer.text(
                    chinese: Self.srtText(translated, sourceFormat: sourceFormat),
                    english: Self.srtText(document.cues[index].text, sourceFormat: sourceFormat),
                    format: .srt,
                    mode: outputMode
                )
                document.cues[index].assFields = nil
            }
            let srtDocument = SubtitleDocument(format: .srt, cues: document.cues)
            progress(PipelineProgress(
                phase: .writingSubtitle,
                completedChunks: chunks.count,
                totalChunks: chunks.count,
                detail: "\(outputMode.displayName) · \(output.lastPathComponent)",
                completedItems: document.cues.count,
                totalItems: document.cues.count
            ))
            if deliveryMode == .sidecarSRT {
                if fileManager.fileExists(atPath: output.path) && !overwrite { throw AppError.outputExists(output) }
                guard input.standardizedFileURL != output.standardizedFileURL else { throw AppError.originalOverwriteForbidden }
                try writer.write(srtDocument, to: output)
                try await jobStore.clear(input: input, trackIndex: track.streamIndex)
                progress(PipelineProgress(
                    phase: .completed,
                    completedChunks: chunks.count,
                    totalChunks: chunks.count,
                    detail: output.lastPathComponent,
                    completedItems: document.cues.count,
                    totalItems: document.cues.count
                ))
                return output
            }

            let subtitleName = outputMode == .bilingual
                ? "\(targetLanguage.outputCode)-bilingual.srt"
                : "\(targetLanguage.outputCode).srt"
            let translatedSubtitle = temporaryRoot.appendingPathComponent(subtitleName)
            try writer.write(srtDocument, to: translatedSubtitle)
            let muxCueCount = document.cues.count
            let trackTitle = outputMode.trackTitle(
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
            let muxDetail = "复制原有视频、音频和字幕轨道，并新增“\(trackTitle)”"
            progress(PipelineProgress(
                phase: .muxing,
                completedChunks: chunks.count,
                totalChunks: chunks.count,
                phaseFraction: 0,
                detail: muxDetail,
                completedItems: muxCueCount,
                totalItems: muxCueCount
            ))
            try await ffmpeg.mux(
                input: input,
                chineseSubtitle: translatedSubtitle,
                output: output,
                existingSubtitleCount: existingSubtitleCount,
                trackTitle: trackTitle,
                languageCode: targetLanguage.iso6392Code,
                overwrite: overwrite,
                durationSeconds: durationSeconds
            ) { fraction in
                progress(PipelineProgress(
                    phase: .muxing,
                    completedChunks: chunks.count,
                    totalChunks: chunks.count,
                    phaseFraction: fraction,
                    detail: muxDetail,
                    completedItems: muxCueCount,
                    totalItems: muxCueCount
                ))
            }
            try await jobStore.clear(input: input, trackIndex: track.streamIndex)
            progress(PipelineProgress(
                phase: .completed,
                completedChunks: chunks.count,
                totalChunks: chunks.count,
                phaseFraction: 1,
                detail: output.lastPathComponent,
                completedItems: document.cues.count,
                totalItems: document.cues.count
            ))
            return output
        } catch is CancellationError {
            throw AppError.cancelled
        }
    }

    private func mergeGlossary(_ existing: [GlossaryEntry], _ updates: [GlossaryEntry]) -> [GlossaryEntry] {
        var result = Array(existing.suffix(500))
        for update in updates where !update.source.isEmpty && !update.target.isEmpty {
            let bounded = GlossaryEntry(
                source: String(update.source.prefix(200)),
                target: String(update.target.prefix(200))
            )
            if let index = result.firstIndex(where: { $0.source.caseInsensitiveCompare(bounded.source) == .orderedSame }) {
                result[index] = bounded
            } else {
                result.append(bounded)
            }
        }
        return Array(result.suffix(500))
    }

    private func translationProgress(
        chunk: TranslationChunk,
        record: TranslationJobRecord,
        allCues: [SubtitleCue],
        totalChunks: Int,
        detailPrefix: String
    ) -> PipelineProgress {
        let completedItems = allCues.reduce(into: 0) { count, cue in
            if record.translatedItems[cue.id] != nil { count += 1 }
        }
        let firstID = chunk.core.first?.id ?? 0
        let lastID = chunk.core.last?.id ?? 0
        return PipelineProgress(
            phase: .translating,
            completedChunks: record.completedChunkIndexes.count,
            totalChunks: totalChunks,
            detail: "\(detailPrefix) · 第 \(chunk.index + 1)/\(totalChunks) 块 · ID \(firstID)–\(lastID) · \(chunk.core.count) 条",
            completedItems: completedItems,
            totalItems: allCues.count
        )
    }

    private static func srtText(_ text: String, sourceFormat: SubtitleFormat) -> String {
        guard sourceFormat == .ass else { return text }
        return text
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
    }
}
