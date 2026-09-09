import Foundation
import Darwin

public enum CodexReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, minimal, low, medium, high, xhigh, max, ultra
    public var id: String { rawValue }
    public var displayName: String {
        AppInterfaceLanguage.localized(self == .none ? "关闭额外推理（速度优先）" : "推理强度") + (self == .none ? "" : " · \(rawValue)")
    }
}

public struct CodexModelCapability: Decodable, Equatable, Sendable, Identifiable {
    public var id: String { model }
    public let model: String
    public let displayName: String
    public let supportedReasoningEfforts: [Effort]
    public let hidden: Bool?
    public let inputModalities: [String]?
    public struct Effort: Decodable, Equatable, Sendable {
        public let reasoningEffort: String
    }
    public var efforts: [CodexReasoningEffort] {
        supportedReasoningEfforts.compactMap { CodexReasoningEffort(rawValue: $0.reasoningEffort) }
    }
    public var translationEfforts: [CodexReasoningEffort] {
        // App Server's picker catalog currently omits `none`, while Luna exec
        // accepts it (verified by the 250/350/500-cue benchmark). Retain that
        // explicit, tested override only for Luna, not unknown future models.
        let supported = Set(efforts + (model == CodexModel.luna.rawValue ? [.none] : []))
        return CodexReasoningEffort.allCases.filter { supported.contains($0) }
    }
}

/// A deliberately small, read-only App Server client. No threads or model turns
/// are created and no authentication files are read by Sub Buddy.
public struct CodexModelCatalog: Sendable {
    public init() {}
    public func refresh(executable: URL?, timeout: TimeInterval = 30) async throws -> [CodexModelCapability] {
        guard let executable else {
            throw AppError.toolMissing(name: "Codex CLI", guidance: "请安装 ChatGPT/Codex 后重试。")
        }
        let session = CatalogProcess(executable: executable)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try session.fetch(timeout: timeout)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            session.stop()
        }
    }

    struct Page: Decodable { let data: [CodexModelCapability]; let nextCursor: String? }
    static func decodePage(_ data: Data) throws -> Page { try JSONDecoder().decode(Page.self, from: data) }
}

private final class CatalogProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var buffer = Data()
    private var bytesRead = 0

    init(executable: URL) {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        // Do not surface raw diagnostics that could contain account metadata.
        process.standardError = FileHandle.nullDevice
    }

    func stop() {
        lock.lock()
        stopped = true
        if process.isRunning { process.terminate() }
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [self] in
            lock.lock()
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            lock.unlock()
        }
    }

    func fetch(timeout: TimeInterval) throws -> [CodexModelCapability] {
        lock.lock()
        do {
            guard !stopped else { throw CancellationError() }
            try process.run()
            lock.unlock()
        } catch { lock.unlock(); throw error }
        let watchdog = DispatchWorkItem { [self] in stop() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0.1, timeout), execute: watchdog)
        defer {
            watchdog.cancel()
            try? input.fileHandleForWriting.close()
            stop()
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "sub_buddy", "version": "0.9.3"]]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        var models: [CodexModelCapability] = []
        var cursors = Set<String>()
        var cursor: String?
        // Both a page limit and repeated-cursor detection prevent unbounded loops.
        for pageIndex in 0..<20 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let id = pageIndex + 2
            try send(["id": id, "method": "model/list", "params": params])
            let page = try CodexModelCatalog.decodePage(response(id: id))
            models.append(contentsOf: page.data.filter {
                $0.hidden != true && ($0.inputModalities?.contains("text") ?? true)
            })
            guard let next = page.nextCursor else {
                var seen = Set<String>()
                let result = models.filter { !$0.model.isEmpty && seen.insert($0.model).inserted }
                guard !result.isEmpty else { throw failure() }
                return result
            }
            guard cursors.insert(next).inserted else { throw failure() }
            cursor = next
        }
        throw failure()
    }

    private func send(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func response(id: Int) throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                buffer.removeSubrange(...newline)
                guard let object, object["id"] as? Int == id else { continue }
                guard object["error"] == nil, let result = object["result"] else { throw failure() }
                return try JSONSerialization.data(withJSONObject: result)
            }
            let data = output.fileHandleForReading.availableData
            bytesRead += data.count
            guard !data.isEmpty, bytesRead <= 4 * 1_024 * 1_024 else { throw failure() }
            buffer.append(data)
        }
    }

    private func failure() -> AppError {
        .invalidTranslation("模型列表刷新失败。请检查连接和登录状态；若仍无效，请更新 Sub Buddy 和 Codex 后重试。")
    }
}
