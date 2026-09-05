import Foundation

public enum BatchJobStatus: String, Codable, Sendable {
    case queued
    case inspecting
    case ready
    case processing
    case completed
    case skipped
    case failed

    public var displayName: String {
        let key: String
        switch self {
        case .queued: key = "等待扫描"
        case .inspecting: key = "正在扫描"
        case .ready: key = "等待处理"
        case .processing: key = "正在处理"
        case .completed: key = "已完成"
        case .skipped: key = "已跳过"
        case .failed: key = "失败"
        }
        return AppInterfaceLanguage.localized(key)
    }
}

public struct BatchJob: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let inputPath: String
    public var isEnabled: Bool
    public var status: BatchJobStatus
    public var detail: String
    public var progressFraction: Double
    public var outputPath: String?
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        inputPath: String,
        isEnabled: Bool = true,
        status: BatchJobStatus = .queued,
        detail: String = "",
        progressFraction: Double = 0,
        outputPath: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.inputPath = inputPath
        self.isEnabled = isEnabled
        self.status = status
        self.detail = detail
        self.progressFraction = min(1, max(0, progressFraction))
        self.outputPath = outputPath
        self.startedAt = startedAt
        self.completedAt = completedAt
    }

    public var inputURL: URL { URL(fileURLWithPath: inputPath) }
    public var fileName: String { inputURL.lastPathComponent }
}

public struct MKVFolderScanner: @unchecked Sendable {
    private static let generatedSuffixExpression = try? NSRegularExpression(
        pattern: #"_(?:en|zh|es|fr|de|ja|ko|pt|ru|ar)(?:_bilingual)?$"#,
        options: .caseInsensitive
    )
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(_ folder: URL) throws -> [URL] {
        try Task.checkCancellation()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        let keySet = Set(keys)
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard url.pathExtension.caseInsensitiveCompare("mkv") == .orderedSame else { continue }
            let values = try? url.resourceValues(forKeys: keySet)
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            urls.append(url)
        }
        let sourceKeys = Set(urls.map(Self.fileKey))
        let filtered = urls.filter { url in
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let expression = Self.generatedSuffixExpression,
                  let match = expression.firstMatch(
                    in: stem,
                    range: NSRange(stem.startIndex..., in: stem)
                  ),
                  let range = Range(match.range, in: stem) else { return true }
            let sourceStem = String(stem[..<range.lowerBound])
            let sourceKey = Self.fileKey(directory: url.deletingLastPathComponent(), stem: sourceStem)
            return !sourceKeys.contains(sourceKey)
        }
        return filtered.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func fileKey(_ url: URL) -> String {
        fileKey(
            directory: url.deletingLastPathComponent(),
            stem: url.deletingPathExtension().lastPathComponent.lowercased()
        )
    }

    private static func fileKey(directory: URL, stem: String) -> String {
        directory.standardizedFileURL.path + "\u{0}" + stem
    }
}

public actor BatchQueueStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private var latestMutationRevision: UInt64 = 0

    public init(fileURL: URL? = nil) {
        let manager = FileManager.default
        fileManager = manager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? manager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? manager.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("MKV Subtitle Translator", isDirectory: true)
                .appendingPathComponent("batch-queue.json")
        }
    }

    public func load() throws -> [BatchJob] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([BatchJob].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ jobs: [BatchJob], revision: UInt64? = nil) throws {
        if let revision {
            guard revision >= latestMutationRevision else { return }
            latestMutationRevision = revision
        }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(jobs).write(to: fileURL, options: .atomic)
    }

    public func clear(revision: UInt64? = nil) throws {
        if let revision {
            guard revision >= latestMutationRevision else { return }
            latestMutationRevision = revision
        }
        if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
    }
}
