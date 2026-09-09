import Foundation

/// Keeps only the most recent source document for retries in the same app session.
/// Never caches translated text, video bytes, or partially completed OCR.
public actor PreparedSubtitleCache {
    struct Key: Equatable, Sendable {
        let path: String
        let size: UInt64
        let modified: Date
        let created: Date?
        let device: UInt64
        let inode: UInt64
        let track: SubtitleTrack
        let recognitionLanguage: String?

        init(input: URL, track: SubtitleTrack, sourceLanguage: SubtitleLanguage) throws {
            let resolved = input.resolvingSymlinksInPath().standardizedFileURL
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                throw CocoaError(.fileReadUnknown)
            }
            self.path = resolved.path
            self.size = size.uint64Value
            self.modified = modified
            self.created = attributes[.creationDate] as? Date
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.track = track
            self.recognitionLanguage = track.isText ? nil : sourceLanguage.recognitionLanguage
        }
    }

    private var entry: (key: Key, document: SubtitleDocument)?
    public init() {}

    func document(for key: Key) -> SubtitleDocument? {
        guard entry?.key == key else { return nil }
        return entry?.document
    }

    func store(_ document: SubtitleDocument, for key: Key) {
        // Bound memory; oversized/unusually long documents remain fully usable,
        // but are prepared again on retry rather than retained indefinitely.
        guard !document.cues.isEmpty, document.cues.count <= 100_000,
              let data = try? JSONEncoder().encode(document), data.count <= 16 * 1_024 * 1_024 else {
            entry = nil
            return
        }
        entry = (key, document)
    }
}
