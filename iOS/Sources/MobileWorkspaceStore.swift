import Foundation

struct MobileWorkspace: Codable, Sendable {
    var sourceName: String
    /// Optional for backward compatibility with workspaces created before 0.3.2.
    var sourceFileExtension: String?
    var movie: MovieInfo
    var session: ManualTranslationSession
    var outputMode: SubtitleOutputMode
    var lowConfidenceCueIDs: [Int]
    var isOCRSource: Bool?
    var sourceLanguage: SubtitleLanguage?
    var targetLanguage: SubtitleLanguage?
}

actor MobileWorkspaceStore {
    private let url: URL
    /// Callers attach a monotonically increasing revision to every mutation.
    /// Unstructured UI tasks can reach this actor out of order; the revision
    /// prevents an older save from resurrecting a workspace after a newer clear.
    private var latestMutationRevision: UInt64 = 0

    init() {
        let fileManager = FileManager.default
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent("MKV Subtitle Translator iOS", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("current-workspace.json")
    }

    func load() throws -> MobileWorkspace? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(MobileWorkspace.self, from: Data(contentsOf: url))
    }

    func save(_ workspace: MobileWorkspace, revision: UInt64) throws {
        guard revision >= latestMutationRevision else { return }
        latestMutationRevision = revision
        try JSONEncoder().encode(workspace).write(to: url, options: .atomic)
    }

    func clear(revision: UInt64) throws {
        guard revision >= latestMutationRevision else { return }
        latestMutationRevision = revision
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
