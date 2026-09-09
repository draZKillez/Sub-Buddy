import Foundation

public enum TranslationItemIssue: String, Sendable {
    case missing, duplicate, empty, sourceMismatch, tagsMismatch, lineBreakMismatch

    var description: String {
        switch self {
        case .missing: return "缺少条目"
        case .duplicate: return "ID 重复"
        case .empty: return "译文为空"
        case .sourceMismatch: return "返回的原文与该 ID 不一致"
        case .tagsMismatch: return "格式标签不一致"
        case .lineBreakMismatch: return "正文行数不一致"
        }
    }

    var repairInstruction: String {
        switch self {
        case .missing: return "This ID was omitted. Return it."
        case .duplicate: return "This ID appeared more than once. Return exactly one item."
        case .empty: return "The translation was empty. Translate all of this cue."
        case .sourceMismatch: return "Copy the exact source from CORE, including punctuation and real line breaks. Do not paraphrase source or borrow a neighboring cue."
        case .tagsMismatch: return "Keep every original markup tag verbatim and in the same order."
        case .lineBreakMismatch: return "Translate each source line separately within this same ID. Keep the same number of nonempty lines; use JSON newline escapes, not literal backslash+n. Do not merge lines."
        }
    }
}

public struct AlignedTranslationResult: Sendable {
    public let response: TranslationResponse
    public let issues: [Int: TranslationItemIssue]
}

public struct TranslationValidator: Sendable {
    public init() {}

    /// Decode once, retain only unambiguous source-bound items for recovery.
    /// Comparing IDs alone cannot detect a model moving a sentence to a neighbor.
    public func alignedPartial(
        rawJSON: String,
        expectedCues: [SubtitleCue],
        requiresSourceEcho: Bool
    ) throws -> TranslationResponse {
        try assessAlignment(rawJSON: rawJSON, expectedCues: expectedCues,
                            requiresSourceEcho: requiresSourceEcho).response
    }

    public func assessAlignment(
        rawJSON: String,
        expectedCues: [SubtitleCue],
        requiresSourceEcho: Bool
    ) throws -> AlignedTranslationResult {
        let data = Data(rawJSON.utf8)
        try validateStrictShape(data)
        let response: TranslationResponse
        do {
            response = try JSONDecoder().decode(TranslationResponse.self, from: data)
        } catch {
            throw AppError.invalidTranslation("无法解析严格 JSON（\(error.localizedDescription)）。")
        }
        let sources = Dictionary(expectedCues.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
        var counts: [Int: Int] = [:]
        for item in response.items { counts[item.id, default: 0] += 1 }
        let extra = Set(counts.keys).subtracting(sources.keys).sorted()
        guard extra.isEmpty else {
            throw AppError.invalidTranslation("出现非核心块 ID：\(extra.map(String.init).joined(separator: ", "))。")
        }
        var issues = Dictionary(uniqueKeysWithValues: sources.keys.map { ($0, TranslationItemIssue.missing) })
        let items = response.items.compactMap { item -> TranslationItem? in
            guard let source = sources[item.id] else { return nil }
            guard counts[item.id] == 1 else { issues[item.id] = .duplicate; return nil }
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues[item.id] = .empty; return nil
            }
            if requiresSourceEcho || item.source != nil {
                guard item.source == source else { issues[item.id] = .sourceMismatch; return nil }
            }
            let text = Self.normalizeLineBreaks(item.text, source: source)
            if requiresSourceEcho, let issue = Self.formattingIssue(text, source: source) {
                issues[item.id] = issue; return nil
            }
            issues.removeValue(forKey: item.id)
            return TranslationItem(
                id: item.id,
                text: text,
                source: item.source
            )
        }
        return AlignedTranslationResult(
            response: TranslationResponse(items: items, glossaryUpdates: response.glossaryUpdates), issues: issues
        )
    }

    private static let markup = try! NSRegularExpression(pattern: #"</?[^>\n]+>|\{\\[^}\n]*\}"#)

    /// Do not silently accept lost styles or collapsed subtitle lines. This is
    /// a structural check, not an assertion that the translation is correct.
    static func preservesFormatting(_ text: String, source: String) -> Bool {
        formattingIssue(text, source: source) == nil
    }

    private static func formattingIssue(_ text: String, source: String) -> TranslationItemIssue? {
        func tags(_ value: String) -> [String] {
            markup.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }
        }
        guard tags(text) == tags(source) else { return .tagsMismatch }
        guard lineCount(text) == lineCount(source) else { return .lineBreakMismatch }
        return nil
    }

    static func lineCount(_ value: String) -> Int {
        value.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .replacingOccurrences(of: #"\N"#, with: "\n")
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// Only repair double-escaped line breaks when the source really has line
    /// breaks and no literal \\n of its own (paths/code must stay intact).
    static func normalizeLineBreaks(_ text: String, source: String) -> String {
        guard source.contains("\n"), !source.contains(#"\n"#), !source.contains(#"\r"#),
              !text.contains("\n") else { return text }
        return text.replacingOccurrences(of: #"\r\n"#, with: "\n")
            .replacingOccurrences(of: #"\n"#, with: "\n")
    }

    public func validate(rawJSON: String, expectedIDs: [Int]) throws -> TranslationResponse {
        let response = try validatePartial(rawJSON: rawJSON, expectedIDs: expectedIDs)
        return try validate(response: response, expectedIDs: expectedIDs)
    }

    /// Accepts a strict, internally valid response that may omit expected IDs.
    /// This lets the engine retain completed translations and request only the
    /// missing tail when a large model response is cut short.
    public func validatePartial(rawJSON: String, expectedIDs: [Int]) throws -> TranslationResponse {
        guard let data = rawJSON.data(using: .utf8) else {
            throw AppError.invalidTranslation("输出不是 UTF-8 文本。")
        }
        try validateStrictShape(data)
        let response: TranslationResponse
        do {
            response = try JSONDecoder().decode(TranslationResponse.self, from: data)
        } catch {
            throw AppError.invalidTranslation("无法解析严格 JSON（\(error.localizedDescription)）。")
        }
        let returnedIDs = response.items.map(\.id)
        let unique = Set(returnedIDs)
        if unique.count != returnedIDs.count {
            throw AppError.invalidTranslation("包含重复字幕 ID。")
        }
        let expected = Set(expectedIDs)
        let extra = unique.subtracting(expected).sorted()
        guard extra.isEmpty else { throw AppError.invalidTranslation("出现非核心块 ID：\(extra.map(String.init).joined(separator: ", "))。") }
        if let empty = response.items.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw AppError.invalidTranslation("字幕 ID \(empty.id) 的译文为空。")
        }
        return response
    }

    public func validate(response: TranslationResponse, expectedIDs: [Int]) throws -> TranslationResponse {
        let returnedIDs = response.items.map(\.id)
        let unique = Set(returnedIDs)
        guard unique.count == returnedIDs.count else {
            throw AppError.invalidTranslation("包含重复字幕 ID。")
        }
        let expected = Set(expectedIDs)
        let missing = expected.subtracting(unique).sorted()
        let extra = unique.subtracting(expected).sorted()
        guard missing.isEmpty else {
            throw AppError.invalidTranslation("缺少 ID：\(missing.map(String.init).joined(separator: ", "))。")
        }
        guard extra.isEmpty else {
            throw AppError.invalidTranslation("出现非核心块 ID：\(extra.map(String.init).joined(separator: ", "))。")
        }
        guard returnedIDs.count == expectedIDs.count else {
            throw AppError.invalidTranslation("字幕数量不匹配。")
        }
        if let empty = response.items.first(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw AppError.invalidTranslation("字幕 ID \(empty.id) 的译文为空。")
        }
        return response
    }

    private func validateStrictShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw AppError.invalidTranslation("无法解析严格 JSON（\(error.localizedDescription)）。")
        }
        guard let root = object as? [String: Any] else {
            throw AppError.invalidTranslation("输出必须是一个 JSON 对象。")
        }
        let allowedRootKeys: Set<String> = ["items", "glossary_updates"]
        let extraRootKeys = Set(root.keys).subtracting(allowedRootKeys)
        guard extraRootKeys.isEmpty else {
            throw AppError.invalidTranslation("JSON 包含额外字段：\(extraRootKeys.sorted().joined(separator: ", "))。")
        }
        guard root["items"] is [[String: Any]] else {
            throw AppError.invalidTranslation("JSON 缺少 items 数组。")
        }
        for item in (root["items"] as? [[String: Any]]) ?? [] {
            let keys = Set(item.keys)
            guard keys == ["id", "text"] || keys == ["id", "source", "text"] else {
                throw AppError.invalidTranslation("items 中每项只能包含 id、source 和 text。")
            }
        }
        if let glossary = root["glossary_updates"] {
            guard let entries = glossary as? [[String: Any]] else {
                throw AppError.invalidTranslation("glossary_updates 必须是数组。")
            }
            for entry in entries where Set(entry.keys) != ["source", "target"] {
                throw AppError.invalidTranslation("glossary_updates 中每项只能包含 source 和 target。")
            }
        }
    }
}
