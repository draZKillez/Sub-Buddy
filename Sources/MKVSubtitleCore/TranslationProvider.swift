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
    var requiresSourceEcho: Bool { get }
    func translate(_ request: TranslationRequest) async throws -> String
}

public extension TranslationProvider {
    var progressLabel: String { "翻译服务" }
    var requiresSourceEcho: Bool { false }
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
        2. 每个输入 ID 必须对应且只对应一个输出 ID；保持 ID 不变，不输出时间轴。逐条输出 id、原样复制的 source、仅对应这条 source 的 text。
        3. 只输出一个严格 JSON 对象，不要 Markdown、代码围栏、解释、前言或尾注。
        4. 保持人物称呼、语气、粗口、幽默和上下文一致，并根据电影类型调整表达。
        5. 保留原字幕换行、斜体、HTML 标签、ASS 标签、声音描述、歌词及括号内容。
        6. 片名、人名、组织、地点及其他专有名词必须跨块统一。
        7. JSON 结构必须为 {"items":[{"id":1,"source":"原文","text":"译文"}],"glossary_updates":[{"source":"Name","target":"译名"}]}。source 必须与该 ID 的输入完全一致。
        8. 不要调用任何工具，不要读取本地文件；仅使用本提示中提供的内容。
        9. 每条 ID 是独立的播放时间窗口。即使一句话跨多条字幕，也绝不能合并、提前翻译下一条、把本条内容挪到前后 ID，或重新编号。允许片段句，只翻译该条原文覆盖的内容。
        10. 例：ID 247="I'll explain this"、ID 248="as simply as I can."，应分别翻译为“我来解释一下”和“尽量说得简单些。”；不能把两条合成一句放进 ID 247，再把后一句挪入 ID 248。
        11. 正文换行按 JSON 的单次转义编码，解码后必须是真实换行；不要输出字面反斜杠+n。生成每项前对照该 ID 的 source，确认 text 没有包含相邻 ID 的对白。

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


            以下是上次输出，仅供参考。只输出当前 CORE 列出的 ID，修正原文与译文对应关系；不要输出已完成 ID，也不要因参考输出而改变当前 CORE：
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
            // A real JSON string avoids ambiguous literal \\n and quote escaping
            // in the old ad-hoc [ID] text format.
            let encoded = (try? JSONEncoder().encode(TranslationSource(id: cue.id, source: cue.text))) ?? Data()
            let line = String(decoding: encoded, as: UTF8.self)
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

    private struct TranslationSource: Encodable {
        let id: Int
        let source: String
    }
}

public struct TranslationEngine: Sendable {
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
        completedItems: [Int: String] = [:],
        onValidated: (TranslationResponse) async throws -> Void = { _ in },
        onRepair: () -> Void = {}
    ) async throws -> TranslationResponse {
        let expectedIDs = chunk.core.map(\.id)
        guard Set(expectedIDs).count == expectedIDs.count else {
            throw AppError.invalidTranslation("输入字幕包含重复 ID。")
        }
        var byID: [Int: TranslationItem] = [:]
        for cue in chunk.core {
            if let text = completedItems[cue.id], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                byID[cue.id] = TranslationItem(id: cue.id, text: text)
            }
        }
        var updates: [GlossaryEntry] = []
        var lastFailure: String?
        // One normal request, then at most two progressively smaller recovery
        // rounds. Both character and cue limits apply to repairs.
        for round in 0..<3 {
            try Task.checkCancellation()
            let pending = chunk.core.filter { byID[$0.id] == nil }
            if pending.isEmpty { break }
            if round > 0 { onRepair() }
            let batches: [[SubtitleCue]]
            if round == 0 {
                batches = [pending]
            } else {
                let limit = round == 1 ? 250 : 125
                batches = TranslationChunker(configuration: .init(
                    targetCoreCount: limit, maximumCoreCount: limit,
                    maximumCoreCharacters: round == 1 ? 30_000 : 15_000,
                    contextCount: 0
                )).chunks(for: pending).map(\.core)
            }
            for cues in batches {
                try Task.checkCancellation()
                let request = TranslationRequest(
                    chunk: recoveryChunk(for: cues, in: chunk),
                    movie: movie,
                    glossary: TranslationGlossary.merge(glossary, updates),
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage
                )
                let raw = try await provider.translate(request)
                try Task.checkCancellation()
                let partial: TranslationResponse
                do {
                    partial = try validator.alignedPartial(
                        rawJSON: raw, expectedCues: cues,
                        requiresSourceEcho: provider.requiresSourceEcho
                    )
                } catch {
                    lastFailure = error.localizedDescription
                    continue
                }
                guard !partial.items.isEmpty else { continue }
                for item in partial.items { byID[item.id] = item }
                updates = TranslationGlossary.merge(updates, partial.glossaryUpdates)
                // Persist outside the parse-error catch: storage errors and
                // cancellation must not be mistaken for model format failures.
                try await onValidated(partial)
            }
        }
        let pendingIDs = expectedIDs.filter { byID[$0] == nil }
        guard pendingIDs.isEmpty else {
            let reason = lastFailure.map { " \($0)" } ?? ""
            throw AppError.invalidTranslation(
                "缺失或原文对应无效的字幕 ID：\(pendingIDs.map(String.init).joined(separator: ", "))。已保存通过校验的条目，重试将只处理剩余条目。\(reason)"
            )
        }
        return try validator.validate(
            response: TranslationResponse(items: expectedIDs.compactMap { byID[$0] }, glossaryUpdates: updates),
            expectedIDs: expectedIDs
        )
    }

    private func recoveryChunk(for cues: [SubtitleCue], in original: TranslationChunk) -> TranslationChunk {
        let missingIDs = Set(cues.map(\.id))
        let all = original.previousContext + original.core + original.nextContext
        guard let firstIndex = all.firstIndex(where: { missingIDs.contains($0.id) }),
              let lastIndex = all.lastIndex(where: { missingIDs.contains($0.id) }) else {
            return TranslationChunk(index: original.index, core: cues,
                previousContext: original.previousContext, nextContext: original.nextContext)
        }
        return TranslationChunk(
            index: original.index,
            core: cues,
            previousContext: Array(all[max(0, firstIndex - Self.recoveryContextCount)..<firstIndex]),
            nextContext: Array(all[(lastIndex + 1)..<min(all.count, lastIndex + 1 + Self.recoveryContextCount)])
        )
    }
}

/// Bound both memory and prompt size. A lookup table avoids repeatedly scanning
/// up to 500 existing terms for every new entry.
enum TranslationGlossary {
    static func merge(_ existing: [GlossaryEntry], _ updates: [GlossaryEntry]) -> [GlossaryEntry] {
        var result: [GlossaryEntry] = []
        var indexes: [String: Int] = [:]
        for entry in existing.suffix(500) + updates {
            let source = String(entry.source.prefix(200))
            let target = String(entry.target.prefix(200))
            guard !source.isEmpty, !target.isEmpty else { continue }
            let key = source.lowercased()
            let bounded = GlossaryEntry(source: source, target: target)
            if let index = indexes[key] {
                result[index] = bounded
            } else {
                indexes[key] = result.count
                result.append(bounded)
            }
        }
        return Array(result.suffix(500))
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
