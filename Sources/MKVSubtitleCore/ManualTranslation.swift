import Foundation

public struct ManualTranslationChunk: Codable, Equatable, Sendable, Identifiable {
    public let index: Int
    public let cues: [SubtitleCue]
    public var id: Int { index }

    public init(index: Int, cues: [SubtitleCue]) {
        self.index = index
        self.cues = cues
    }
}

public struct ManualSRTValidator: Sendable {
    private let parser = SubtitleParser()

    public init() {}

    public func validate(_ pastedText: String, expectedCues: [SubtitleCue]) throws -> [SubtitleCue] {
        guard !expectedCues.isEmpty else {
            throw AppError.manualSubtitleFormat("当前分段没有字幕。")
        }
        let cleaned = normalizeCommonTimelineFormatting(stripCodeFence(pastedText))
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError.manualSubtitleFormat("粘贴内容为空。")
        }
        let firstLine = cleaned
            .split(whereSeparator: \Character.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == String(expectedCues[0].id) else {
            throw AppError.manualSubtitleFormat("内容必须直接从字幕 ID \(expectedCues[0].id) 开始，不能包含前言或说明。")
        }

        let parsed: SubtitleDocument
        do {
            parsed = try parser.parse(data: Data(cleaned.utf8), format: .srt)
        } catch {
            throw AppError.manualSubtitleFormat(error.localizedDescription)
        }
        guard parsed.cues.count == expectedCues.count else {
            throw AppError.manualSubtitleFormat("应有 \(expectedCues.count) 条，实际解析到 \(parsed.cues.count) 条。")
        }

        var seen = Set<Int>()
        for (actual, expected) in zip(parsed.cues, expectedCues) {
            guard seen.insert(actual.id).inserted else {
                throw AppError.manualSubtitleFormat("字幕 ID \(actual.id) 重复。")
            }
            guard actual.id == expected.id else {
                throw AppError.manualSubtitleFormat("ID 顺序不正确：此处应为 \(expected.id)，实际为 \(actual.id)。")
            }
            guard actual.startMilliseconds == expected.startMilliseconds,
                  actual.endMilliseconds == expected.endMilliseconds else {
                throw AppError.manualSubtitleFormat("字幕 ID \(expected.id) 的时间轴被修改。")
            }
            guard !actual.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.manualSubtitleFormat("字幕 ID \(expected.id) 的正文为空。")
            }
        }
        return parsed.cues
    }

    private func stripCodeFence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }
        guard let firstNewline = trimmed.firstIndex(of: "\n"),
              let closingRange = trimmed.range(of: "```", options: .backwards),
              closingRange.lowerBound > firstNewline else { return trimmed }
        let suffix = trimmed[closingRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard suffix.isEmpty else { return trimmed }
        let bodyStart = trimmed.index(after: firstNewline)
        return String(trimmed[bodyStart..<closingRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Translation tools occasionally rewrite the visual punctuation in an SRT
    /// timeline even when explicitly asked not to. Repair only the syntax of a
    /// complete timestamp line; the parsed millisecond values are still compared
    /// with the source cues below, so an actual timing change remains an error.
    private func normalizeCommonTimelineFormatting(_ text: String) -> String {
        let pattern = #"(?m)^\s*(\d{1,2})[:：](\d{2})[:：](\d{2})[,，\.．](\d{3})\s*(?:-->|->|→|⟶|—>|–>|−>)\s*(\d{1,2})[:：](\d{2})[:：](\d{2})[,，\.．](\d{3})\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "$1:$2:$3,$4 --> $5:$6:$7,$8"
        )
    }
}

public struct ManualTranslationSession: Codable, Equatable, Sendable {
    public private(set) var sourceDocument: SubtitleDocument
    public let chunkSize: Int
    public private(set) var translatedItems: [Int: String]
    public private(set) var completedChunkIndexes: Set<Int>
    public var currentChunkIndex: Int

    public init(document: SubtitleDocument, chunkSize: Int) {
        let normalizedCues = document.cues.map { cue in
            var normalized = cue
            if document.format == .ass {
                normalized.text = normalized.text
                    .replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
            }
            normalized.assFields = nil
            return normalized
        }
        self.sourceDocument = SubtitleDocument(format: .srt, cues: normalizedCues)
        self.chunkSize = max(1, min(chunkSize, 1_000))
        self.translatedItems = [:]
        self.completedChunkIndexes = []
        self.currentChunkIndex = 0
    }

    private enum CodingKeys: String, CodingKey {
        case sourceDocument, chunkSize, translatedItems, completedChunkIndexes, currentChunkIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let document = try container.decode(SubtitleDocument.self, forKey: .sourceDocument)
        let ids = document.cues.map(\.id)
        guard !ids.isEmpty, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceDocument,
                in: container,
                debugDescription: "手动翻译进度为空，或包含无效/重复字幕 ID。"
            )
        }
        sourceDocument = document
        chunkSize = max(1, min(try container.decode(Int.self, forKey: .chunkSize), 1_000))
        let validIDs = Set(ids)
        translatedItems = try container.decode([Int: String].self, forKey: .translatedItems)
            .filter { validIDs.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        currentChunkIndex = try container.decodeIfPresent(Int.self, forKey: .currentChunkIndex) ?? 0
        completedChunkIndexes = []

        let decodedCompleted = try container.decodeIfPresent(Set<Int>.self, forKey: .completedChunkIndexes) ?? []
        completedChunkIndexes = Set((0..<totalChunkCount).compactMap { index in
            guard decodedCompleted.contains(index),
                  let chunk = chunk(at: index),
                  chunk.cues.allSatisfy({ translatedItems[$0.id] != nil }) else { return nil }
            return index
        })
        currentChunkIndex = (0..<totalChunkCount).contains(currentChunkIndex) ? currentChunkIndex : 0
    }

    public var chunks: [ManualTranslationChunk] {
        (0..<totalChunkCount).compactMap(chunk(at:))
    }

    public var currentChunk: ManualTranslationChunk? {
        chunk(at: currentChunkIndex)
    }

    public var completedChunkCount: Int { completedChunkIndexes.count }
    public var totalChunkCount: Int {
        guard !sourceDocument.cues.isEmpty else { return 0 }
        return (sourceDocument.cues.count + chunkSize - 1) / chunkSize
    }
    public var isComplete: Bool { totalChunkCount > 0 && completedChunkIndexes.count == totalChunkCount }

    public func copyText(
        movie: MovieInfo,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese
    ) throws -> String {
        guard let chunk = currentChunk else {
            throw AppError.manualSubtitleFormat("没有可复制的当前分段。")
        }
        let document = SubtitleDocument(format: .srt, cues: chunk.cues)
        let srt = try SubtitleWriter().string(from: document)
        let year = movie.year.map(String.init) ?? "未知"
        let chineseTitle = movie.chineseTitle.isEmpty ? "未填写" : movie.chineseTitle
        return """
        请将以下影视 SRT 字幕从 \(sourceLanguage.promptName) 翻译成自然、地道、口语化的 \(targetLanguage.promptName)。
        原始片名：\(movie.originalTitle)
        目标语言片名：\(chineseTitle)
        年份：\(year)

        规则：
        1. 只翻译字幕正文，序号和时间轴必须原样保留。
        2. 不得遗漏、增加、合并或拆分字幕条目。
        3. 保留正文中的换行、HTML 标签、声音描述、歌词及括号内容。
        4. 只输出完整 SRT，不要 Markdown 代码围栏、解释、前言或尾注。

        \(srt)
        """
    }

    public func existingTranslationText() throws -> String {
        guard let chunk = currentChunk,
              chunk.cues.allSatisfy({ translatedItems[$0.id] != nil }) else { return "" }
        let cues = chunk.cues.map { cue in
            var translated = cue
            translated.text = translatedItems[cue.id] ?? ""
            return translated
        }
        return try SubtitleWriter().string(from: SubtitleDocument(format: .srt, cues: cues))
    }

    public func currentSourceText() throws -> String {
        guard let chunk = currentChunk else { return "" }
        return try SubtitleWriter().string(from: SubtitleDocument(format: .srt, cues: chunk.cues))
    }

    public mutating func applyCurrentSourceCorrection(_ srt: String, validator: ManualSRTValidator = .init()) throws {
        guard let chunk = currentChunk else {
            throw AppError.manualSubtitleFormat("没有可校对的当前分段。")
        }
        let corrected = try validator.validate(srt, expectedCues: chunk.cues)
        let correctedByID = Dictionary(uniqueKeysWithValues: corrected.map { ($0.id, $0.text) })
        for index in sourceDocument.cues.indices {
            let id = sourceDocument.cues[index].id
            if let text = correctedByID[id] { sourceDocument.cues[index].text = text }
        }
        for cue in chunk.cues { translatedItems[cue.id] = nil }
        completedChunkIndexes.remove(chunk.index)
    }

    public mutating func applyCurrentTranslation(_ pastedText: String, validator: ManualSRTValidator = .init()) throws {
        guard let chunk = currentChunk else {
            throw AppError.manualSubtitleFormat("没有可保存的当前分段。")
        }
        let validated = try validator.validate(pastedText, expectedCues: chunk.cues)
        for cue in validated { translatedItems[cue.id] = cue.text }
        completedChunkIndexes.insert(chunk.index)
        if let next = (0..<totalChunkCount).first(where: { !completedChunkIndexes.contains($0) }) {
            currentChunkIndex = next
        }
    }

    public mutating func move(to index: Int) {
        guard (0..<totalChunkCount).contains(index) else { return }
        currentChunkIndex = index
    }

    public func mergedDocument(outputMode: SubtitleOutputMode) throws -> SubtitleDocument {
        guard isComplete else {
            throw AppError.manualSubtitleFormat("还有 \(max(0, totalChunkCount - completedChunkCount)) 份尚未完成。")
        }
        let composer = SubtitleOutputComposer()
        let cues = try sourceDocument.cues.map { source -> SubtitleCue in
            guard let chinese = translatedItems[source.id] else {
                throw AppError.manualSubtitleFormat("缺少字幕 ID \(source.id) 的译文。")
            }
            var result = source
            result.text = composer.text(
                chinese: chinese,
                english: source.text,
                format: .srt,
                mode: outputMode
            )
            return result
        }
        return SubtitleDocument(format: .srt, cues: cues)
    }

    private func chunk(at index: Int) -> ManualTranslationChunk? {
        guard index >= 0 else { return nil }
        let start = index.multipliedReportingOverflow(by: chunkSize)
        guard !start.overflow,
              start.partialValue < sourceDocument.cues.count else { return nil }
        let end = min(sourceDocument.cues.count, start.partialValue + chunkSize)
        return ManualTranslationChunk(
            index: index,
            cues: Array(sourceDocument.cues[start.partialValue..<end])
        )
    }
}

#if os(macOS)
public struct ManualAIFormatCheckResult: Codable, Equatable, Sendable {
    public let valid: Bool
    public let issues: [String]

    public init(valid: Bool, issues: [String]) {
        self.valid = valid
        self.issues = issues
    }
}

public struct CodexManualFormatChecker: Sendable {
    private let bridge: CodexBridge

    public init(bridge: CodexBridge) {
        self.bridge = bridge
    }

    public func check(srt: String, expectedCues: [SubtitleCue]) async throws -> ManualAIFormatCheckResult {
        let expectedIDs = expectedCues.map(\.id)
        let prompt = """
        你只负责检查下面的 SRT 格式，不得评价翻译质量、准确性、措辞或语言风格，也不得改写字幕。
        检查项目仅限：SRT 是否可解析；字幕 ID 是否严格等于给定列表且无重复/缺失；每条是否有时间轴和非空正文。
        只输出严格 JSON：{"valid":true,"issues":[]}；如有问题，在 issues 中用简体中文简短说明。
        预期 ID：\(expectedIDs)

        待检查 SRT：
        \(srt)
        """
        let raw = try await bridge.executeTranslation(prompt: prompt)
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(ManualAIFormatCheckResult.self, from: data) else {
            throw AppError.invalidTranslation("AI 格式检查没有返回严格 JSON。")
        }
        return result
    }
}
#endif
