import Foundation

/// Deterministic, bounded work allocation. The model dispatches these tasks;
/// it does not invent IDs, sizes or ownership. Each session has fresh children
/// per task to avoid growing translator conversations indefinitely.
public enum CodexSubtitleTaskPlanner {
    public static let maximumSessionCues = 2_400
    public static let directTranslationLimit = 300
    public static let maximumTaskCharacters = 30_000

    public static func tasks(for request: TranslationRequest) throws -> [TranslationRequest] {
        let core = request.chunk.core
        guard !core.isEmpty, core.count <= maximumSessionCues,
              Set(core.map(\.id)).count == core.count else {
            throw AppError.invalidTranslation("字幕队列必须非空、ID 唯一，且每个调度会话不超过 2400 条。")
        }
        guard core.allSatisfy({ $0.text.count <= maximumTaskCharacters }) else {
            throw AppError.invalidTranslation("单条字幕超过 30000 字符，请先检查原字幕内容。")
        }
        let minimum = (core.count + directTranslationLimit - 1) / directTranslationLimit
        // Balance the tail for two workers: e.g. 2000 -> 8 x 250, not
        // 6 x 300 + 200 with one idle worker at the end.
        let count = core.count <= directTranslationLimit ? 1 : minimum + minimum % 2
        let all = request.chunk.previousContext + core + request.chunk.nextContext
        var tasks: [TranslationRequest] = []
        var start = 0
        for index in 0..<count {
            let size = core.count / count + (index < core.count % count ? 1 : 0)
            let end = start + size
            let bounded = TranslationChunker(configuration: .init(
                targetCoreCount: directTranslationLimit, maximumCoreCount: directTranslationLimit,
                maximumCoreCharacters: maximumTaskCharacters, contextCount: 0
            )).chunks(for: Array(core[start..<end]))
            var cursor = start
            for task in bounded {
                let lower = request.chunk.previousContext.count + cursor
                let upper = lower + task.core.count
                tasks.append(TranslationRequest(
                    chunk: .init(index: tasks.count, core: task.core,
                        previousContext: Array(all[max(0, lower - 50)..<lower]),
                        nextContext: Array(all[upper..<min(all.count, upper + 50)])),
                    movie: request.movie, glossary: request.glossary,
                    previousInvalidOutput: request.previousInvalidOutput,
                    sourceLanguage: request.sourceLanguage, targetLanguage: request.targetLanguage))
                cursor += task.core.count
            }
            start = end
        }
        return tasks
    }
}

public enum CodexTranslationReasoningPolicy {
    /// `none` is always selected when off. Availability is checked separately,
    /// so an unsupported model cannot silently select another effort/model.
    public static func effort(subagents: Bool, supported: [CodexReasoningEffort]) -> CodexReasoningEffort? {
        guard subagents else { return CodexReasoningEffort.none }
        return CodexReasoningEffort.allCases.first { $0 != .none && supported.contains($0) }
    }
}
