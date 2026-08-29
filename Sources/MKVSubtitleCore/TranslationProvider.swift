import Foundation

public struct TranslationRequest: Equatable, Sendable {
    public let chunk: TranslationChunk
    public let movie: MovieInfo
    public let glossary: [GlossaryEntry]
    public let previousInvalidOutput: String?
    public let sourceLanguage: SubtitleLanguage
    public let targetLanguage: SubtitleLanguage

    public init(
        chunk: TranslationChunk,
        movie: MovieInfo,
        glossary: [GlossaryEntry],
        previousInvalidOutput: String? = nil,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese
    ) {
        self.chunk = chunk
        self.movie = movie
        self.glossary = glossary
        self.previousInvalidOutput = previousInvalidOutput
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public protocol TranslationProvider: Sendable {
    var progressLabel: String { get }
    func translate(_ request: TranslationRequest) async throws -> String
}

public extension TranslationProvider {
    var progressLabel: String { "翻译服务" }
}

public struct TranslationPromptBuilder: Sendable {
    public init() {}

    public func build(_ request: TranslationRequest) -> String {
        let year = request.movie.year.map(String.init) ?? "未知"
        let chineseTitle = request.movie.chineseTitle.isEmpty ? "未填写（可选）" : request.movie.chineseTitle
        var prompt = """
        你是专业影视字幕译者。请把下面核心字幕从 \(request.sourceLanguage.promptName) 翻译为自然、地道、口语化的 \(request.targetLanguage.promptName)。

        固定电影信息：
        原始片名：\(request.movie.originalTitle)
        目标语言片名：\(chineseTitle)
        年份：\(year)

        硬性规则：
        1. 只翻译 CORE 中的字幕；BEFORE 和 AFTER 仅供理解，绝不能输出。
        2. 每个输入 ID 必须对应且只对应一个输出 ID；保持 ID 不变，不输出时间轴。
        3. 只输出一个严格 JSON 对象，不要 Markdown、代码围栏、解释、前言或尾注。
        4. 保持人物称呼、语气、粗口、幽默和上下文一致，并根据电影类型调整表达。
        5. 保留原字幕换行、斜体、HTML 标签、ASS 标签、声音描述、歌词及括号内容。
        6. 片名、人名、组织、地点及其他专有名词必须跨块统一。
        7. JSON 结构必须为 {"items":[{"id":1,"text":"中文字幕"}],"glossary_updates":[{"source":"Name","target":"译名"}]}。
        8. 不要调用任何工具，不要读取本地文件；仅使用本提示中提供的内容。

        当前术语表：
        \(jsonString(Array(request.glossary.suffix(500))))

        BEFORE（只作上下文）：
        \(cueLines(request.chunk.previousContext, maximumCharacters: 20_000))

        CORE（只翻译这些 ID）：
        \(cueLines(request.chunk.core))

        AFTER（只作上下文）：
        \(cueLines(request.chunk.nextContext, maximumCharacters: 20_000))
        """
        if let invalid = request.previousInvalidOutput {
            prompt += """


            上一次输出未通过格式校验。请仅修复格式和 ID 对应关系，不要省略内容，并重新输出完整严格 JSON：
            \(String(invalid.prefix(200_000)))
            """
        }
        return prompt
    }

    private func cueLines(_ cues: [SubtitleCue], maximumCharacters: Int? = nil) -> String {
        guard !cues.isEmpty else { return "（无）" }
        var lines: [String] = []
        var count = 0
        for cue in cues {
            let escaped = cue.text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
            let line = "[\(cue.id)] \(escaped)"
            if let maximumCharacters, !lines.isEmpty, count + line.count + 1 > maximumCharacters {
                lines.append("（其余上下文因长度限制省略）")
                break
            }
            lines.append(line)
            count += line.count + 1
        }
        return lines.joined(separator: "\n")
    }

    private func jsonString(_ value: [GlossaryEntry]) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct TranslationEngine: Sendable {
    private static let maximumRecoveryBatchSize = 250
    private static let recoveryContextCount = 50
    private let provider: TranslationProvider
    private let validator: TranslationValidator

    public init(provider: TranslationProvider, validator: TranslationValidator = .init()) {
        self.provider = provider
        self.validator = validator
    }

    public func translate(
        chunk: TranslationChunk,
        movie: MovieInfo,
        glossary: [GlossaryEntry],
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese,
        onRepair: () -> Void = {}
    ) async throws -> TranslationResponse {
        let request = TranslationRequest(
            chunk: chunk,
            movie: movie,
            glossary: glossary,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        let first = try await provider.translate(request)
        do {
            return try validator.validate(rawJSON: first, expectedIDs: chunk.core.map(\.id))
        } catch {
            onRepair()
            if let partial = try? validator.validatePartial(
                rawJSON: first,
                expectedIDs: chunk.core.map(\.id)
            ) {
                let returnedIDs = Set(partial.items.map(\.id))
                let missingCues = chunk.core.filter { !returnedIDs.contains($0.id) }
                if !partial.items.isEmpty, !missingCues.isEmpty {
                    let missingChunk = recoveryChunk(for: missingCues, in: chunk)
                    let recoveryChunks = splitForRecovery(missingChunk)
                    var recovered: [TranslationResponse] = []
                    for recoveryChunk in recoveryChunks {
                        try Task.checkCancellation()
                        recovered.append(try await recover(
                            chunk: recoveryChunk,
                            movie: movie,
                            glossary: glossary + partial.glossaryUpdates + recovered.flatMap(\.glossaryUpdates),
                            sourceLanguage: sourceLanguage,
                            targetLanguage: targetLanguage
                        ))
                    }
                    return try merged(
                        responses: [partial] + recovered,
                        expectedIDs: chunk.core.map(\.id)
                    )
                }
            }

            // If the JSON itself was truncated, complete a single recovery
            // round in bounded batches. Large 500-item output is the common
            // failure mode; 250-item batches stay comfortably below it.
            let recoveryChunks = splitForRecovery(chunk)
            var responses: [TranslationResponse] = []
            for recoveryChunk in recoveryChunks {
                try Task.checkCancellation()
                responses.append(try await recover(
                    chunk: recoveryChunk,
                    movie: movie,
                    glossary: glossary + responses.flatMap(\.glossaryUpdates),
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    previousInvalidOutput: recoveryChunks.count == 1 ? first : nil
                ))
            }
            return try merged(responses: responses, expectedIDs: chunk.core.map(\.id))
        }
    }

    /// Completes one bounded recovery batch. A partially valid response is
    /// retained and only its missing IDs are submitted once more. This avoids
    /// repeatedly retranslating hundreds of successful cues while guaranteeing
    /// that recovery is finite rather than an unbounded retry loop.
    private func recover(
        chunk: TranslationChunk,
        movie: MovieInfo,
        glossary: [GlossaryEntry],
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage,
        previousInvalidOutput: String? = nil
    ) async throws -> TranslationResponse {
        let raw = try await provider.translate(TranslationRequest(
            chunk: chunk,
            movie: movie,
            glossary: glossary,
            previousInvalidOutput: previousInvalidOutput,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ))
        let expectedIDs = chunk.core.map(\.id)
        if let complete = try? validator.validate(rawJSON: raw, expectedIDs: expectedIDs) {
            return complete
        }

        if let partial = try? validator.validatePartial(rawJSON: raw, expectedIDs: expectedIDs),
           !partial.items.isEmpty {
            let returnedIDs = Set(partial.items.map(\.id))
            let missingCues = chunk.core.filter { !returnedIDs.contains($0.id) }
            guard !missingCues.isEmpty else {
                return try validator.validate(response: partial, expectedIDs: expectedIDs)
            }
            let missingChunk = recoveryChunk(for: missingCues, in: chunk)
            let repairedRaw = try await provider.translate(TranslationRequest(
                chunk: missingChunk,
                movie: movie,
                glossary: glossary + partial.glossaryUpdates,
                previousInvalidOutput: raw,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            ))
            let repaired = try validator.validate(
                rawJSON: repairedRaw,
                expectedIDs: missingCues.map(\.id)
            )
            return try merged(responses: [partial, repaired], expectedIDs: expectedIDs)
        }

        // The batch contained no safely reusable items (for example truncated
        // JSON). Make exactly one format-repair request for this bounded batch.
        let repairedRaw = try await provider.translate(TranslationRequest(
            chunk: chunk,
            movie: movie,
            glossary: glossary,
            previousInvalidOutput: raw,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        ))
        return try validator.validate(rawJSON: repairedRaw, expectedIDs: expectedIDs)
    }

    private func recoveryChunk(for cues: [SubtitleCue], in original: TranslationChunk) -> TranslationChunk {
        let missingIDs = Set(cues.map(\.id))
        let all = original.previousContext + original.core + original.nextContext
        guard let firstIndex = all.firstIndex(where: { missingIDs.contains($0.id) }),
              let lastIndex = all.lastIndex(where: { missingIDs.contains($0.id) }) else {
            return TranslationChunk(
                index: original.index,
                core: cues,
                previousContext: original.previousContext,
                nextContext: original.nextContext
            )
        }
        let previousStart = max(0, firstIndex - Self.recoveryContextCount)
        let nextEnd = min(all.count, lastIndex + 1 + Self.recoveryContextCount)
        return TranslationChunk(
            index: original.index,
            core: cues,
            previousContext: all[previousStart..<firstIndex].filter { !missingIDs.contains($0.id) },
            nextContext: all[(lastIndex + 1)..<nextEnd].filter { !missingIDs.contains($0.id) }
        )
    }

    private func splitForRecovery(_ chunk: TranslationChunk) -> [TranslationChunk] {
        guard chunk.core.count > Self.maximumRecoveryBatchSize else { return [chunk] }
        var result: [TranslationChunk] = []
        var start = 0
        while start < chunk.core.count {
            let end = min(chunk.core.count, start + Self.maximumRecoveryBatchSize)
            let previous = Array((chunk.previousContext + chunk.core[..<start]).suffix(Self.recoveryContextCount))
            let next = Array((chunk.core[end...] + chunk.nextContext).prefix(Self.recoveryContextCount))
            result.append(TranslationChunk(
                index: chunk.index,
                core: Array(chunk.core[start..<end]),
                previousContext: previous,
                nextContext: next
            ))
            start = end
        }
        return result
    }

    private func merged(
        responses: [TranslationResponse],
        expectedIDs: [Int]
    ) throws -> TranslationResponse {
        let byID = Dictionary(uniqueKeysWithValues: responses.flatMap(\.items).map { ($0.id, $0) })
        let response = TranslationResponse(
            items: expectedIDs.compactMap { byID[$0] },
            glossaryUpdates: responses.flatMap(\.glossaryUpdates)
        )
        return try validator.validate(response: response, expectedIDs: expectedIDs)
    }
}

public actor MockTranslationProvider: TranslationProvider {
    public enum Mode: Sendable { case success, malformedThenSuccess }
    private var callCount = 0
    private let mode: Mode

    public init(mode: Mode = .success) { self.mode = mode }

    public func translate(_ request: TranslationRequest) async throws -> String {
        callCount += 1
        if mode == .malformedThenSuccess && callCount == 1 { return "不是 JSON" }
        let items = request.chunk.core.map { TranslationItem(id: $0.id, text: "【模拟翻译】\($0.text)") }
        let response = TranslationResponse(items: items)
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    public func numberOfCalls() -> Int { callCount }
}
