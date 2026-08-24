import Foundation

public struct TranslationJobRecord: Codable, Equatable, Sendable {
    public let inputPath: String
    public let trackIndex: Int
    public var translatedItems: [Int: String]
    public var glossary: [GlossaryEntry]
    public var completedChunkIndexes: Set<Int>
    public var updatedAt: Date
    public var sourceLanguageCode: String?
    public var targetLanguageCode: String?
    public var translationContext: String?

    public init(
        inputPath: String,
        trackIndex: Int,
        translatedItems: [Int: String] = [:],
        glossary: [GlossaryEntry] = [],
        completedChunkIndexes: Set<Int> = [],
        updatedAt: Date = Date(),
        sourceLanguageCode: String? = nil,
        targetLanguageCode: String? = nil,
        translationContext: String? = nil
    ) {
        self.inputPath = inputPath
        self.trackIndex = trackIndex
        self.translatedItems = translatedItems
        self.glossary = glossary
        self.completedChunkIndexes = completedChunkIndexes
        self.updatedAt = updatedAt
        self.sourceLanguageCode = sourceLanguageCode
        self.targetLanguageCode = targetLanguageCode
        self.translationContext = translationContext
    }
}

public actor JobStore {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil) {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fileManager.temporaryDirectory
            self.rootURL = base.appendingPathComponent("MKV Subtitle Translator/Jobs", isDirectory: true)
        }
    }

    public func load(input: URL, trackIndex: Int) throws -> TranslationJobRecord? {
        let candidates = [
            recordURL(input: input, trackIndex: trackIndex),
            previousRecordURL(input: input, trackIndex: trackIndex),
            legacyRecordURL(input: input, trackIndex: trackIndex)
        ]
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranslationJobRecord.self, from: Data(contentsOf: sourceURL))
    }

    public func save(_ record: TranslationJobRecord, input: URL) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        var updated = record
        updated.updatedAt = Date()
        let encoder = JSONEncoder()
        // Progress can contain thousands of subtitle strings. Default compact,
        // unsorted JSON avoids both pretty-print bytes and unnecessary key sorting.
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(updated).write(to: recordURL(input: input, trackIndex: record.trackIndex), options: .atomic)
    }

    public func clear(input: URL, trackIndex: Int) throws {
        for url in [
            recordURL(input: input, trackIndex: trackIndex),
            previousRecordURL(input: input, trackIndex: trackIndex),
            legacyRecordURL(input: input, trackIndex: trackIndex)
        ] {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
    }

    private func recordURL(input: URL, trackIndex: Int) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let raw = "\(input.resolvingSymlinksInPath().standardizedFileURL.path)-\(size)-\(modified.bitPattern)-\(device)-\(inode)-\(trackIndex)"
        return rootURL.appendingPathComponent(ProgressFileKey.name(
            prefix: input.deletingPathExtension().lastPathComponent,
            identity: raw,
            suffix: "translation-progress.json"
        ))
    }

    /// Compatibility with 0.4.1, whose hashed identity omitted the directory.
    private func previousRecordURL(input: URL, trackIndex: Int) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(input.lastPathComponent)-\(size)-\(Int64(modified))-\(trackIndex)"
        return rootURL.appendingPathComponent(ProgressFileKey.name(
            prefix: input.deletingPathExtension().lastPathComponent,
            identity: raw,
            suffix: "translation-progress.json"
        ))
    }

    private func legacyRecordURL(input: URL, trackIndex: Int) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(input.lastPathComponent)-\(size)-\(Int64(modified))-\(trackIndex)"
        let safe = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return rootURL.appendingPathComponent(String(safe.prefix(180)) + ".translation-progress.json")
    }
}
