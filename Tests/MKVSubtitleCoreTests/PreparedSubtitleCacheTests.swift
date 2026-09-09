import XCTest
@testable import MKVSubtitleCore

final class PreparedSubtitleCacheTests: XCTestCase {
    func testCacheInvalidatesFileAndTrackChangesAndPreservesSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Movie.mkv")
        try Data([1]).write(to: input)
        func track(_ index: Int = 2, codec: String = "subrip") -> SubtitleTrack {
            .init(streamIndex: index, codec: codec, language: "eng", title: "", isDefault: false,
                  isForced: false, isSDH: false, isText: codec == "subrip")
        }
        let cache = PreparedSubtitleCache()
        let key = try PreparedSubtitleCache.Key(input: input, track: track(), sourceLanguage: .english)
        var document = SubtitleDocument(format: .srt, cues: [
            .init(id: 99, startMilliseconds: 100, endMilliseconds: 200, text: "Original\nline")
        ])
        await cache.store(document, for: key)
        document.cues[0].text = "Translated"
        let cached = await cache.document(for: key)
        XCTAssertEqual(cached?.cues[0].text, "Original\nline")
        XCTAssertNotEqual(key, try PreparedSubtitleCache.Key(input: input, track: track(3), sourceLanguage: .english))
        XCTAssertEqual(key, try PreparedSubtitleCache.Key(input: input, track: track(), sourceLanguage: .japanese))
        let ocrKey = try PreparedSubtitleCache.Key(input: input, track: track(codec: "dvd_subtitle"), sourceLanguage: .english)
        XCTAssertNotEqual(ocrKey, try PreparedSubtitleCache.Key(input: input, track: track(codec: "dvd_subtitle"), sourceLanguage: .japanese))
        try Data([1, 2]).write(to: input)
        let changed = try PreparedSubtitleCache.Key(input: input, track: track(), sourceLanguage: .english)
        XCTAssertNotEqual(key, changed)
        let stale = await cache.document(for: changed)
        XCTAssertNil(stale)
        // A same-size edit with a new timestamp also invalidates the cache.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: input.path)
        XCTAssertNotEqual(changed, try PreparedSubtitleCache.Key(input: input, track: track(), sourceLanguage: .english))
        await cache.store(document, for: changed)
        let evicted = await cache.document(for: key)
        XCTAssertNil(evicted, "Only the most recent document is retained")
    }
}
