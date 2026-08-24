import Foundation

public struct TranslationChunker: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var targetCoreCount: Int
        public var maximumCoreCount: Int
        public var maximumCoreCharacters: Int
        public var contextCount: Int

        public init(
            targetCoreCount: Int = 500,
            maximumCoreCount: Int = 500,
            maximumCoreCharacters: Int = 80_000,
            contextCount: Int = 50
        ) {
            self.targetCoreCount = max(1, min(targetCoreCount, maximumCoreCount))
            self.maximumCoreCount = max(1, maximumCoreCount)
            self.maximumCoreCharacters = max(1, maximumCoreCharacters)
            self.contextCount = max(0, contextCount)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func chunks(for cues: [SubtitleCue]) -> [TranslationChunk] {
        guard !cues.isEmpty else { return [] }
        let estimatedCount = (cues.count - 1) / configuration.targetCoreCount + 1
        var chunks: [TranslationChunk] = []
        chunks.reserveCapacity(estimatedCount)
        var start = 0
        while start < cues.count {
            var end = start
            var characters = 0
            while end < cues.count && end - start < configuration.maximumCoreCount {
                let nextCharacters = characters + cues[end].text.count
                if end > start && nextCharacters > configuration.maximumCoreCharacters { break }
                characters = nextCharacters
                end += 1
                if end - start >= configuration.targetCoreCount { break }
            }
            if end == start { end += 1 }
            let previousStart = max(0, start - configuration.contextCount)
            let nextEnd = min(cues.count, end + configuration.contextCount)
            chunks.append(TranslationChunk(
                index: chunks.count,
                core: Array(cues[start..<end]),
                previousContext: Array(cues[previousStart..<start]),
                nextContext: Array(cues[end..<nextEnd])
            ))
            start = end
        }
        return chunks
    }
}
