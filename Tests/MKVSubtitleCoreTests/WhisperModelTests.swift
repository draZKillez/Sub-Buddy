import XCTest
@testable import MKVSubtitleCore

final class WhisperModelTests: XCTestCase {
    func testRecommendedModelIsSmallAndEveryChoiceHasGuidance() {
        XCTAssertEqual(WhisperModel.recommended, .small)
        XCTAssertEqual(WhisperModel.allCases.map(\.rawValue), ["base", "small", "medium", "large-v3-turbo"])
        for model in WhisperModel.allCases {
            XCTAssertFalse(model.strengths.isEmpty)
            XCTAssertFalse(model.limitations.isEmpty)
            XCTAssertFalse(model.downloadSizeText.isEmpty)
            XCTAssertTrue(model.downloadURL.absoluteString.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/"))
            XCTAssertEqual(model.expectedSHA1.count, 40)
        }
    }

    func testModelStoreDistinguishesMissingDamagedAndExpectedSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WhisperModelStore(rootURL: root)
        XCTAssertEqual(store.state(for: .base), .notDownloaded)

        let url = store.fileURL(for: .base)
        try Data("incomplete".utf8).write(to: url)
        XCTAssertEqual(store.state(for: .base), .damaged)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(WhisperModel.base.expectedByteCount))
        try handle.close()
        XCTAssertEqual(store.state(for: .base), .installed)

        try store.delete(.base)
        XCTAssertEqual(store.state(for: .base), .notDownloaded)
    }
}
