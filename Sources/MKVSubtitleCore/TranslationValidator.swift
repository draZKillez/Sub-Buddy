import Foundation

public struct TranslationValidator: Sendable {
    public init() {}

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
            guard Set(item.keys) == ["id", "text"] else {
                throw AppError.invalidTranslation("items 中每项只能包含 id 和 text。")
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
