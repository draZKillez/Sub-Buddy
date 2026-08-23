import Foundation

public enum CodexConnectionStatus: Equatable, Sendable {
    case cliMissing
    case notLoggedIn
    case loggedIn
    case modelUnavailable
    case quotaOrServiceUnavailable

    public var displayName: String {
        let key: String
        switch self {
        case .cliMissing: key = "未检测到 Codex CLI"
        case .notLoggedIn: key = "未登录"
        case .loggedIn: key = "已登录"
        case .modelUnavailable: key = "模型不可用"
        case .quotaOrServiceUnavailable: key = "当前额度或服务不可用"
        }
        return AppInterfaceLanguage.localized(key)
    }
}

public enum CodexModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case luna = "gpt-5.6-luna"
    case terra = "gpt-5.6-terra"
    case sol = "gpt-5.6-sol"

    public var id: String { rawValue }

    public var displayName: String {
        let key: String
        switch self {
        case .luna: key = "GPT-5.6 Luna（高吞吐）"
        case .terra: key = "GPT-5.6 Terra（均衡）"
        case .sol: key = "GPT-5.6 Sol（质量优先）"
        }
        return AppInterfaceLanguage.localized(key)
    }

    public var detail: String {
        let key: String
        switch self {
        case .luna: key = "适合大量字幕，默认推荐"
        case .terra: key = "速度和表达质量更均衡"
        case .sol: key = "质量优先，通常等待更久"
        }
        return AppInterfaceLanguage.localized(key)
    }
}

public struct CodexJSONLParser: Sendable {
    public init() {}

    public func finalAgentMessage(from jsonl: String) throws -> String {
        var finalMessage: String?
        for line in jsonl.split(whereSeparator: \.isNewline) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }
            if type == "item.completed",
               let item = object["item"] as? [String: Any],
               item["type"] as? String == "agent_message",
               let text = item["text"] as? String {
                finalMessage = text
            }
            if type == "turn.failed" || type == "error" {
                let message = (object["message"] as? String)
                    ?? ((object["error"] as? [String: Any])?["message"] as? String)
                    ?? "Codex 返回失败事件。"
                throw AppError.processFailed(tool: "Codex", code: 1, message: message)
            }
        }
        guard let finalMessage else {
            throw AppError.invalidTranslation("Codex JSONL 中没有最终 agent_message。")
        }
        return finalMessage
    }
}

public final class CodexBridge: @unchecked Sendable {
    public static let defaultModel = CodexModel.luna.rawValue
    public let model: String
    private let codexURL: URL?
    private let executor: ProcessExecuting
    private let jsonlParser: CodexJSONLParser

    public init(
        codexURL: URL?,
        model: String = CodexBridge.defaultModel,
        executor: ProcessExecuting = ProcessExecutor(),
        jsonlParser: CodexJSONLParser = .init()
    ) {
        self.codexURL = codexURL
        self.model = model
        self.executor = executor
        self.jsonlParser = jsonlParser
    }

    public func connectionStatus() async -> CodexConnectionStatus {
        guard let codexURL else { return .cliMissing }
        do {
            let result = try await executor.run(executable: codexURL, arguments: ["login", "status"], standardInput: nil)
            let combined = (result.standardOutput + "\n" + result.standardError).lowercased()
            if result.status == 0 && (combined.contains("logged in") || combined.contains("chatgpt")) { return .loggedIn }
            return .notLoggedIn
        } catch {
            return .notLoggedIn
        }
    }

    public func login() async throws {
        guard let codexURL else {
            throw AppError.toolMissing(name: "Codex CLI", guidance: "请安装 ChatGPT/Codex，并确保 codex 可执行文件存在。")
        }
        let result = try await executor.run(executable: codexURL, arguments: ["login"], standardInput: nil)
        guard result.status == 0 else {
            throw AppError.processFailed(tool: "Codex login", code: result.status, message: result.standardError)
        }
    }

    public func executeTranslation(prompt: String) async throws -> String {
        guard let codexURL else {
            throw AppError.toolMissing(name: "Codex CLI", guidance: "安装 ChatGPT/Codex 后，点击“连接 ChatGPT”。")
        }
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MKVSubtitleTranslator-Codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        let arguments = [
            "exec",
            "--ephemeral",
            "--json",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "-c", "model_reasoning_effort=\"none\"",
            "-C", workingDirectory.path,
            "-m", model,
            "-"
        ]
        let result = try await executor.run(executable: codexURL, arguments: arguments, standardInput: Data(prompt.utf8))
        guard result.status == 0 else { throw classifyFailure(result.standardError + "\n" + result.standardOutput, status: result.status) }
        do {
            return try jsonlParser.finalAgentMessage(from: result.standardOutput)
        } catch let appError as AppError {
            if case let .processFailed(_, code, message) = appError {
                throw classifyFailure(message, status: code)
            }
            throw appError
        }
    }

    private func classifyFailure(_ message: String, status: Int32) -> AppError {
        let lowered = message.lowercased()
        if lowered.contains("not logged") || lowered.contains("login required") || lowered.contains("authentication") || lowered.contains("unauthorized") {
            return .codexNotLoggedIn
        }
        if lowered.contains("model") && (lowered.contains("not found") || lowered.contains("not available") || lowered.contains("unsupported") || lowered.contains("access")) {
            return .codexModelUnavailable(model)
        }
        if lowered.contains("quota") || lowered.contains("rate limit") || lowered.contains("usage limit") || lowered.contains("credits") {
            return .codexQuotaUnavailable
        }
        if lowered.contains("service unavailable") || lowered.contains("temporarily unavailable") || lowered.contains("connection") || lowered.contains("network") {
            return .codexServiceUnavailable
        }
        return .processFailed(tool: "Codex", code: status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public struct CodexTranslationProvider: TranslationProvider {
    private let bridge: CodexBridge
    private let promptBuilder: TranslationPromptBuilder

    public init(bridge: CodexBridge, promptBuilder: TranslationPromptBuilder = .init()) {
        self.bridge = bridge
        self.promptBuilder = promptBuilder
    }

    public var progressLabel: String { "Codex · \(bridge.model)" }

    public func translate(_ request: TranslationRequest) async throws -> String {
        try Task.checkCancellation()
        let prompt = promptBuilder.build(request)
        guard prompt.utf8.count <= 1_500_000 else {
            throw AppError.invalidTranslation("本块字幕上下文超过 1.5 MB 安全上限，请减小每块字幕数量后重试。")
        }
        return try await bridge.executeTranslation(prompt: prompt)
    }
}

public struct CodexMovieMetadataProvider: MovieMetadataProvider {
    private let bridge: CodexBridge

    public init(bridge: CodexBridge) {
        self.bridge = bridge
    }

    public func chineseTitleCandidates(originalTitle: String, year: Int?) async throws -> [String] {
        let yearText = year.map(String.init) ?? "未知"
        let prompt = """
        根据以下电影原名和年份，给出最多 3 个可信的简体中文片名候选，常见正式译名优先。
        原名：\(originalTitle)
        年份：\(yearText)
        只输出严格 JSON，不要 Markdown 或解释：{"candidates":["候选一","候选二"]}
        如果无法可靠判断，输出 {"candidates":[]}。不要使用任何工具。
        """
        let raw = try await bridge.executeTranslation(prompt: prompt)
        guard let data = raw.data(using: .utf8),
              let response = try? JSONDecoder().decode(CandidateResponse.self, from: data) else {
            throw AppError.invalidTranslation("中文片名候选不是严格 JSON。")
        }
        var seen = Set<String>()
        return response.candidates.compactMap { candidate in
            let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }.prefix(3).map { $0 }
    }

    private struct CandidateResponse: Decodable {
        let candidates: [String]
    }
}
