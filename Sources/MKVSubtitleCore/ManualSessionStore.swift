import Foundation

public actor ManualSessionStore {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL? = nil) {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? fileManager.temporaryDirectory
            self.rootURL = base.appendingPathComponent("MKV Subtitle Translator/Manual Jobs", isDirectory: true)
        }
    }

    public func load(
        input: URL,
        trackIndex: Int,
        chunkSize: Int,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese
    ) throws -> ManualTranslationSession? {
        let url = recordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        let previous = previousRecordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        let canUseLegacy = sourceLanguage == .english && targetLanguage == .simplifiedChinese
        let legacy = legacyRecordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize)
        let candidates = canUseLegacy ? [url, previous, legacy] : [url, previous]
        guard let sourceURL = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else { return nil }
        return try JSONDecoder().decode(ManualTranslationSession.self, from: Data(contentsOf: sourceURL))
    }

    public func save(
        _ session: ManualTranslationSession,
        input: URL,
        trackIndex: Int,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese
    ) throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(session)
        try data.write(
            to: recordURL(input: input, trackIndex: trackIndex, chunkSize: session.chunkSize, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage),
            options: .atomic
        )
    }

    public func clear(
        input: URL,
        trackIndex: Int,
        chunkSize: Int,
        sourceLanguage: SubtitleLanguage = .english,
        targetLanguage: SubtitleLanguage = .simplifiedChinese
    ) throws {
        var urls = [
            recordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage),
            previousRecordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        ]
        // Only the original English→Chinese pair ever used the legacy file.
        if sourceLanguage == .english && targetLanguage == .simplifiedChinese {
            urls.append(legacyRecordURL(input: input, trackIndex: trackIndex, chunkSize: chunkSize))
        }
        for url in urls where fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func recordURL(
        input: URL,
        trackIndex: Int,
        chunkSize: Int,
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage
    ) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let raw = "\(input.resolvingSymlinksInPath().standardizedFileURL.path)-\(size)-\(modified.bitPattern)-\(device)-\(inode)-\(trackIndex)-\(chunkSize)-\(sourceLanguage.rawValue)-\(targetLanguage.rawValue)"
        return rootURL.appendingPathComponent(ProgressFileKey.name(
            prefix: input.deletingPathExtension().lastPathComponent,
            identity: raw,
            suffix: "manual-progress.json"
        ))
    }

    /// Compatibility with 0.4.1, whose hashed identity omitted the directory.
    private func previousRecordURL(
        input: URL,
        trackIndex: Int,
        chunkSize: Int,
        sourceLanguage: SubtitleLanguage,
        targetLanguage: SubtitleLanguage
    ) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(input.lastPathComponent)-\(size)-\(Int64(modified))-\(trackIndex)-\(chunkSize)-\(sourceLanguage.rawValue)-\(targetLanguage.rawValue)"
        return rootURL.appendingPathComponent(ProgressFileKey.name(
            prefix: input.deletingPathExtension().lastPathComponent,
            identity: raw,
            suffix: "manual-progress.json"
        ))
    }

    private func legacyRecordURL(input: URL, trackIndex: Int, chunkSize: Int) -> URL {
        let attributes = try? fileManager.attributesOfItem(atPath: input.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(input.lastPathComponent)-\(size)-\(Int64(modified))-\(trackIndex)-\(chunkSize)"
        let safe = raw.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? String($0) : "_"
        }.joined()
        return rootURL.appendingPathComponent(String(safe.prefix(180)) + ".manual-progress.json")
    }
}
