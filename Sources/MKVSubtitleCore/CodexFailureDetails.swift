import Foundation

/// Extract only failure events, not successful subtitles or the whole JSONL
/// transcript. Some CLI versions wrap service JSON inside a message string.
struct CodexFailureDetails {
    let message: String
    let code: String?

    var summary: String { (code.map { "[\($0)] " } ?? "") + message }

    static func parse(_ transcript: String) -> CodexFailureDetails {
        let tail = String(transcript.suffix(256_000))
        if let object = json(tail), let result = unwrap(object, depth: 0) { return result }
        for line in tail.split(whereSeparator: \.isNewline).reversed() {
            guard let object = json(String(line)) as? [String: Any],
                  let type = object["type"] as? String,
                  type == "error" || type == "turn.failed",
                  let result = unwrap(object, depth: 0) else { continue }
            return result
        }
        // Plain stderr is useful for CLI flag/runtime failures. JSON events,
        // which may contain subtitle content, must never become the UI error.
        let plain = tail.split(whereSeparator: \.isNewline).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("{")
        }.suffix(2).joined(separator: " ")
        return .init(message: sanitized(plain.isEmpty ? "Codex 未提供可解析的错误信息。" : plain), code: nil)
    }

    private static func json(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private static func unwrap(_ value: Any, depth: Int, inheritedCode: String? = nil) -> CodexFailureDetails? {
        guard depth < 6 else { return nil }
        if let text = value as? String {
            if let object = json(text), let nested = unwrap(object, depth: depth + 1, inheritedCode: inheritedCode) { return nested }
            return .init(message: sanitized(text), code: inheritedCode)
        }
        guard let object = value as? [String: Any] else { return nil }
        let code = (object["code"] as? String).map { String(sanitized($0).prefix(80)) } ?? inheritedCode
        if let error = object["error"], let nested = unwrap(error, depth: depth + 1, inheritedCode: code) { return nested }
        if let message = object["message"] { return unwrap(message, depth: depth + 1, inheritedCode: code) }
        return nil
    }

    private static func sanitized(_ text: String) -> String {
        var result = text
        for pattern in [
            #"(?i)Bearer\s+[^\s\"',}]+"#,
            #"\bsk-[A-Za-z0-9_-]+"#,
            #"(?i)(?:access_token|refresh_token|api_key|authorization)[\"']?\s*[:=]\s*[\"']?[^\s\"',}]+"#
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        let compact = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(compact.prefix(600)) + (compact.count > 600 ? "…" : "")
    }
}
