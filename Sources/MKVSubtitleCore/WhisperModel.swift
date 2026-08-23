import CryptoKit
import Foundation

public enum WhisperModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case base
    case small
    case medium
    case largeV3Turbo = "large-v3-turbo"

    public var id: String { rawValue }
    public static let recommended: WhisperModel = .small

    public var modelFileName: String {
        switch self {
        case .base: return "ggml-base.en.bin"
        case .small: return "ggml-small.en.bin"
        case .medium: return "ggml-medium.en.bin"
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        }
    }

    public var displayName: String {
        let key = switch self {
        case .base: "Base · 英文专用"
        case .small: "Small · 英文专用（推荐）"
        case .medium: "Medium · 英文专用"
        case .largeV3Turbo: "Large v3 Turbo"
        }
        return AppInterfaceLanguage.localized(key)
    }

    public var downloadSizeText: String {
        switch self {
        case .base: return "约 142 MiB"
        case .small: return "约 466 MiB"
        case .medium, .largeV3Turbo: return "约 1.5 GiB"
        }
    }

    public var strengths: String {
        let key = switch self {
        case .base:
            "下载小、启动快、内存占用低，适合较老的 Intel Mac 和快速预览。"
        case .small:
            "英文准确率、速度和资源占用最均衡，适合大多数电影和剧集。"
        case .medium:
            "英文听写更细致，口音、快语速和复杂对白通常比 Small 更稳。"
        case .largeV3Turbo:
            "接近大型模型的识别质量，同时针对速度优化；Apple Silicon 上更有优势。"
        }
        return AppInterfaceLanguage.localized(key)
    }

    public var limitations: String {
        let key = switch self {
        case .base:
            "嘈杂场景、口音和人物专名更容易识别错误，不适合质量优先。"
        case .small:
            "极嘈杂或多人重叠对白仍可能漏词；质量低于 Medium 和 Turbo。"
        case .medium:
            "下载和内存占用明显增大，Intel Mac 识别整部电影可能较慢。"
        case .largeV3Turbo:
            "模型较大、耗内存；它不是英文专用模型，老 Intel Mac 上不建议使用。"
        }
        return AppInterfaceLanguage.localized(key)
    }

    public var expectedByteCount: Int64 {
        switch self {
        case .base: return 147_964_211
        case .small: return 487_614_201
        case .medium: return 1_533_774_781
        case .largeV3Turbo: return 1_624_555_275
        }
    }

    // Published by whisper.cpp for the exact converted model files.
    public var expectedSHA1: String {
        switch self {
        case .base: return "137c40403d78fd54d454da0f9bd998f78703390c"
        case .small: return "db8a495a91d927739e50b3fc1cc4c6b8f6c2d022"
        case .medium: return "8c30f0e44ce9560643ebd10bbe50cd20eafd3723"
        case .largeV3Turbo: return "4af2b29d7ec73d781377bfd1758ca957a807e941"
        }
    }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFileName)")!
    }
}

public enum WhisperModelState: Equatable, Sendable {
    case notDownloaded
    case installed
    case damaged
}

public struct WhisperModelStore: Sendable {
    public let rootURL: URL

    public init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base
                .appendingPathComponent("AI Viewing Companion", isDirectory: true)
                .appendingPathComponent("Whisper Models", isDirectory: true)
        }
    }

    public func fileURL(for model: WhisperModel) -> URL {
        rootURL.appendingPathComponent(model.modelFileName)
    }

    public func state(for model: WhisperModel) -> WhisperModelState {
        let url = fileURL(for: model)
        guard FileManager.default.fileExists(atPath: url.path) else { return .notDownloaded }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return size == model.expectedByteCount ? .installed : .damaged
    }

    public func delete(_ model: WhisperModel) throws {
        let url = fileURL(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func download(
        _ model: WhisperModel,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let temporary = rootURL.appendingPathComponent(".\(model.modelFileName).\(UUID().uuidString).download")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let downloader = ModelDownloadOperation(progress: progress)
        let downloaded = try await downloader.download(from: model.downloadURL)
        try FileManager.default.moveItem(at: downloaded, to: temporary)
        try await Self.verify(temporary, model: model)

        let destination = fileURL(for: model)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(1)
        return destination
    }

    private static func verify(_ url: URL, model: WhisperModel) async throws {
        try await Task.detached(priority: .utility) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value == model.expectedByteCount else {
                throw AppError.modelDownload("文件大小不正确，下载可能不完整。请重新下载。")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = Insecure.SHA1()
            while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == model.expectedSHA1 else {
                throw AppError.modelDownload("SHA-1 校验失败，文件可能损坏或被替换。请重新下载。")
            }
        }.value
    }
}

private final class ModelDownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var downloadedURL: URL?
    private var moveError: Error?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func download(from url: URL) async throws -> URL {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        }, onCancel: {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let retained = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIViewingCompanion-Whisper-\(UUID().uuidString).download")
        do {
            try FileManager.default.moveItem(at: location, to: retained)
            lock.lock(); downloadedURL = retained; lock.unlock()
        } catch {
            lock.lock(); moveError = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let resultURL = downloadedURL
        let storedError = moveError
        lock.unlock()
        session.finishTasksAndInvalidate()
        if let error { continuation?.resume(throwing: error) }
        else if let storedError { continuation?.resume(throwing: storedError) }
        else if let resultURL { continuation?.resume(returning: resultURL) }
        else { continuation?.resume(throwing: AppError.modelDownload("下载完成但未找到临时文件。")) }
    }
}
