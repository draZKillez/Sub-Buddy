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

public struct CodexModel: RawRepresentable, Hashable, CaseIterable, Codable, Identifiable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let luna = Self(rawValue: "gpt-5.6-luna")
    public static let terra = Self(rawValue: "gpt-5.6-terra")
    public static let sol = Self(rawValue: "gpt-5.6-sol")
    public static let allCases: [Self] = [.luna, .terra, .sol]

    public var id: String { rawValue }

    public var displayName: String {
        let key: String
        switch self {
        case .luna: key = "GPT-5.6 Luna（高吞吐）"
        case .terra: key = "GPT-5.6 Terra（均衡）"
        case .sol: key = "GPT-5.6 Sol（质量优先）"
        default: return rawValue
        }
        return AppInterfaceLanguage.localized(key)
    }

    public var detail: String {
        let key: String
        switch self {
        case .luna: key = "适合大量字幕，默认推荐"
        case .terra: key = "速度和表达质量更均衡"
        case .sol: key = "质量优先，通常等待更久"
        default: return rawValue
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
    public let reasoningEffort: CodexReasoningEffort
    private let codexURL: URL?
    private let executor: ProcessExecuting
    private let jsonlParser: CodexJSONLParser

    public init(
        codexURL: URL?,
        model: String = CodexBridge.defaultModel,
        reasoningEffort: CodexReasoningEffort = .none,
        executor: ProcessExecuting = ProcessExecutor(),
        jsonlParser: CodexJSONLParser = .init()
    ) {
        self.codexURL = codexURL
        self.model = model
        self.reasoningEffort = reasoningEffort
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

    public func executeTranslation(prompt: String, outputSchema: Data? = nil) async throws -> String {
        let result = try await executeSession(prompt: prompt, outputSchema: outputSchema)
        do {
            return try jsonlParser.finalAgentMessage(from: result.standardOutput)
        } catch let appError as AppError {
            if case let .processFailed(_, code, message) = appError {
                throw classifyFailure(message, status: code)
            }
            throw appError
        }
    }

    func executeSubagents(prompt: String, outputSchema: Data,
                         onEvent: (Data) async throws -> Void) async throws {
        _ = try await executeSession(prompt: prompt, outputSchema: outputSchema, subagents: true, onEvent: onEvent)
    }

    private func executeSession(prompt: String, outputSchema: Data?, subagents: Bool = false,
                                onEvent: (Data) async throws -> Void = { _ in }) async throws -> ProcessResult {
        guard let codexURL else {
            throw AppError.toolMissing(name: "Codex CLI", guidance: "安装 ChatGPT/Codex 后，点击“连接 ChatGPT”。")
        }
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MKVSubtitleTranslator-Codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        var arguments = [
            "exec",
            "--ephemeral",
            "--json",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "-c", "model_reasoning_effort=\"\(reasoningEffort.rawValue)\"",
            "-C", workingDirectory.path
        ]
        if subagents {
            // No separate account, API key, API client or independent CLI lane.
            // Strict config rejects unsupported CLI versions instead of ignoring
            // the session's two-child limit.
            let encodedModel = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
            arguments += ["--strict-config", "-c", "agents.enabled=true",
                          "-c", "agents.max_concurrent_threads_per_session=2",
                          "-c", "agents.default_subagent_model=\(encodedModel)",
                          "-c", "agents.default_subagent_reasoning_effort=\"\(reasoningEffort.rawValue)\""]
        }
        if let outputSchema {
            let schemaURL = workingDirectory.appendingPathComponent("translation.schema.json")
            try outputSchema.write(to: schemaURL, options: .atomic)
            arguments += ["--output-schema", schemaURL.path]
        }
        arguments += ["-m", model, "-"]
        let requestArguments = arguments
        let result: ProcessResult
        if subagents {
            result = try await executeEventStream(executable: codexURL, arguments: requestArguments,
                                                 input: Data(prompt.utf8), onEvent: onEvent)
        } else {
            result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            group.addTask { [executor] in
                try await executor.run(executable: codexURL, arguments: requestArguments, standardInput: Data(prompt.utf8))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                throw AppError.codexServiceUnavailable
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            return result
            }
        }
        guard result.status == 0 else { throw classifyFailure(result.standardError + "\n" + result.standardOutput, status: result.status) }
        return result
    }

    private func executeEventStream(executable: URL, arguments: [String], input: Data,
                                    onEvent: (Data) async throws -> Void) async throws -> ProcessResult {
        let pair = AsyncThrowingStream<Data, Error>.makeStream()
        let producer = Task { [executor] in
            do {
                let result = try await withThrowingTaskGroup(of: ProcessResult.self) { group in
                    group.addTask {
                        if let streaming = executor as? DataStreamingProcessExecuting {
                            return try await streaming.run(executable: executable, arguments: arguments, standardInput: input) {
                                pair.continuation.yield($0)
                            }
                        }
                        // Dependency-injected executors may provide a complete
                        // transcript. Production uses byte streaming above.
                        let result = try await executor.run(executable: executable, arguments: arguments, standardInput: input)
                        pair.continuation.yield(Data(result.standardOutput.utf8))
                        return result
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                        throw AppError.codexServiceUnavailable
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw CancellationError() }
                    return result
                }
                pair.continuation.finish()
                return result
            } catch {
                pair.continuation.finish(throwing: error)
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            do {
                var framer = CodexJSONLFramer()
                for try await data in pair.stream {
                    try Task.checkCancellation()
                    for line in try framer.append(data) { try await onEvent(line) }
                }
                if let line = try framer.finish() { try await onEvent(line) }
                return try await producer.value
            } catch {
                producer.cancel()
                pair.continuation.finish()
                _ = try? await producer.value
                if let appError = error as? AppError, case let .processFailed(_, code, message) = appError {
                    throw classifyFailure(message, status: code)
                }
                throw error
            }
        } onCancel: {
            producer.cancel()
            pair.continuation.finish(throwing: CancellationError())
        }
    }

    private func classifyFailure(_ message: String, status: Int32) -> AppError {
        let lowered = message.lowercased()
        if (lowered.contains("unknown") || lowered.contains("unexpected") || lowered.contains("unrecognized")) &&
            (lowered.contains("agents.") || lowered.contains("strict-config")) {
            return .toolMissing(name: "Codex subagents", guidance: "请更新 Codex CLI；此版本不支持官方子智能体配置，不会静默改用其他翻译方式。")
        }
        if lowered.contains("--output-schema") && (lowered.contains("unexpected") || lowered.contains("unknown")) {
            return .toolMissing(name: "Codex structured output", guidance: "请更新 Codex CLI 后重试；本版本不会静默关闭 Schema 校验。")
        }
        if lowered.contains("not logged") || lowered.contains("login required") || lowered.contains("authentication") || lowered.contains("unauthorized") {
            return .codexNotLoggedIn
        }
        if lowered.contains("model") && (lowered.contains("not found") || lowered.contains("not available") || lowered.contains("unsupported") || lowered.contains("access")) {
            return .codexModelUnavailable(model)
        }
        if lowered.contains("quota") || lowered.contains("rate limit") || lowered.contains("rate_limit") || lowered.contains("429") || lowered.contains("usage limit") || lowered.contains("credits") {
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
    public var requiresSourceEcho: Bool { true }

    public func translate(_ request: TranslationRequest) async throws -> String {
        try Task.checkCancellation()
        let prompt = promptBuilder.build(request)
        guard prompt.utf8.count <= 1_500_000 else {
            throw AppError.invalidTranslation("本块字幕上下文超过 1.5 MB 安全上限，请减小每块字幕数量后重试。")
        }
        return try await bridge.executeTranslation(prompt: prompt, outputSchema: TranslationOutputSchema.data(for: request.chunk.core))
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
