import Foundation
import XCTest
@testable import MKVSubtitleCore

final class ManualTranslationTests: XCTestCase {
    private func document(_ count: Int) -> SubtitleDocument {
        SubtitleDocument(format: .srt, cues: (1...count).map { id in
            SubtitleCue(
                id: id,
                startMilliseconds: Int64(id * 1_000),
                endMilliseconds: Int64(id * 1_000 + 800),
                text: "English \(id)"
            )
        })
    }

    func testManualSessionSplitsAtChosenSizeAndBuildsCopyablePrompt() throws {
        var session = ManualTranslationSession(document: document(1_201), chunkSize: 500)
        XCTAssertEqual(session.chunks.map { $0.cues.count }, [500, 500, 201])
        XCTAssertEqual(session.totalChunkCount, 3)
        session.move(to: 1)
        let text = try session.copyText(movie: MovieInfo(originalTitle: "Demo", chineseTitle: "示例", year: 2026))
        XCTAssertTrue(text.contains("序号和时间轴必须原样保留"))
        XCTAssertTrue(text.contains("501\n00:08:21,000 --> 00:08:21,800"))
        XCTAssertTrue(text.contains("1000\n00:16:40,000 --> 00:16:40,800"))
    }

    func testManualValidatorAcceptsCodeFenceAndRejectsTimelineOrExplanation() throws {
        let expected = Array(document(2).cues)
        let valid = """
        ```srt
        1
        00:00:01,000 --> 00:00:01,800
        你好

        2
        00:00:02,000 --> 00:00:02,800
        世界
        ```
        """
        XCTAssertEqual(try ManualSRTValidator().validate(valid, expectedCues: expected).map(\.text), ["你好", "世界"])

        let changedTimeline = valid.replacingOccurrences(of: "00:00:01,800", with: "00:00:01,900")
        XCTAssertThrowsError(try ManualSRTValidator().validate(changedTimeline, expectedCues: expected))
        XCTAssertThrowsError(try ManualSRTValidator().validate("翻译如下：\n" + valid, expectedCues: expected))
        XCTAssertThrowsError(try ManualSRTValidator().validate(valid + "\n格式已保留", expectedCues: expected))
    }

    func testManualValidatorRepairsCommonAIMangledTimelinePunctuation() throws {
        let expected = Array(document(2).cues)
        let translated = """
        1
        00:00:01,000 -> 00:00:01,800
        你好

        2
        00：00：02，000 → 00：00：02，800
        世界
        """
        let result = try ManualSRTValidator().validate(translated, expectedCues: expected)
        XCTAssertEqual(result.map(\.text), ["你好", "世界"])

        let actuallyChangedTime = translated.replacingOccurrences(of: "02，800", with: "02，900")
        XCTAssertThrowsError(try ManualSRTValidator().validate(actuallyChangedTime, expectedCues: expected))
    }

    func testManualValidatorRejectsMissingLaterIDAndTrailingExplanationBlock() {
        let expected = Array(document(2).cues)
        let missingSecondID = """
        1
        00:00:01,000 --> 00:00:01,800
        你好

        00:00:02,000 --> 00:00:02,800
        世界
        """
        XCTAssertThrowsError(try ManualSRTValidator().validate(missingSecondID, expectedCues: expected))

        let trailingExplanation = """
        1
        00:00:01,000 --> 00:00:01,800
        你好

        2
        00:00:02,000 --> 00:00:02,800
        世界

        翻译完成，请查收。
        """
        XCTAssertThrowsError(try ManualSRTValidator().validate(trailingExplanation, expectedCues: expected))
    }

    func testManualChunksMergeInOriginalOrderAndCanBuildBilingualSRT() throws {
        var session = ManualTranslationSession(document: document(5), chunkSize: 2)
        while !session.isComplete {
            let chunk = try XCTUnwrap(session.currentChunk)
            let translated = chunk.cues.map { cue in
                SubtitleCue(
                    id: cue.id,
                    startMilliseconds: cue.startMilliseconds,
                    endMilliseconds: cue.endMilliseconds,
                    text: "中文 \(cue.id)"
                )
            }
            let text = try SubtitleWriter().string(from: SubtitleDocument(format: .srt, cues: translated))
            try session.applyCurrentTranslation(text)
        }
        let merged = try session.mergedDocument(outputMode: .bilingual)
        XCTAssertEqual(merged.cues.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(merged.cues[0].text, "中文 1\nEnglish 1")
        XCTAssertEqual(merged.cues[4].text, "中文 5\nEnglish 5")
    }

    func testManualSessionDecodingClampsZeroChunkSizeAndCleansInvalidIndexes() throws {
        let original = ManualTranslationSession(document: document(3), chunkSize: 2)
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["chunkSize"] = 0
        object["currentChunkIndex"] = 999
        object["completedChunkIndexes"] = [0, 99]
        let damaged = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ManualTranslationSession.self, from: damaged)
        XCTAssertEqual(decoded.chunkSize, 1)
        XCTAssertEqual(decoded.totalChunkCount, 3)
        XCTAssertEqual(decoded.currentChunkIndex, 0)
        XCTAssertEqual(decoded.completedChunkCount, 0)
    }

    func testManualSessionDecodingRejectsDuplicateSourceIDs() throws {
        let duplicateDocument = SubtitleDocument(format: .srt, cues: [
            SubtitleCue(id: 1, startMilliseconds: 1_000, endMilliseconds: 1_500, text: "One"),
            SubtitleCue(id: 1, startMilliseconds: 2_000, endMilliseconds: 2_500, text: "Duplicate")
        ])
        let original = ManualTranslationSession(document: duplicateDocument, chunkSize: 2)
        let encoded = try JSONEncoder().encode(original)
        XCTAssertThrowsError(try JSONDecoder().decode(ManualTranslationSession.self, from: encoded))
    }

    func testManualSessionDecodingRejectsCorruptTimelineAndBody() throws {
        for invalidCue in [
            SubtitleCue(id: 1, startMilliseconds: 2_000, endMilliseconds: 1_000, text: "Backwards"),
            SubtitleCue(id: 1, startMilliseconds: 1_000, endMilliseconds: 2_000, text: "   ")
        ] {
            let original = ManualTranslationSession(
                document: SubtitleDocument(format: .srt, cues: [invalidCue]),
                chunkSize: 1
            )
            let encoded = try JSONEncoder().encode(original)
            XCTAssertThrowsError(try JSONDecoder().decode(ManualTranslationSession.self, from: encoded))
        }
    }

    func testOCRSourceCorrectionPreservesTimelineAndUpdatesCopyPrompt() throws {
        var session = ManualTranslationSession(document: document(2), chunkSize: 2)
        let corrected = """
        1
        00:00:01,000 --> 00:00:01,800
        Corrected first line

        2
        00:00:02,000 --> 00:00:02,800
        Corrected second line
        """
        try session.applyCurrentSourceCorrection(corrected)
        XCTAssertEqual(session.sourceDocument.cues.map(\.text), ["Corrected first line", "Corrected second line"])
        XCTAssertTrue(try session.copyText(movie: MovieInfo(originalTitle: "Demo")).contains("Corrected first line"))
    }

    func testOptionalCodexCheckerOnlyRequestsFormatReview() async throws {
        let executor = ManualFormatCheckExecutor()
        let bridge = CodexBridge(codexURL: URL(fileURLWithPath: "/tmp/codex"), executor: executor)
        let result = try await CodexManualFormatChecker(bridge: bridge).check(
            srt: "1\n00:00:01,000 --> 00:00:01,800\n你好\n",
            expectedCues: [document(1).cues[0]]
        )
        XCTAssertTrue(result.valid)
        let prompt = String(decoding: try XCTUnwrap(executor.standardInput), as: UTF8.self)
        XCTAssertTrue(prompt.contains("不得评价翻译质量"))
        XCTAssertTrue(prompt.contains("也不得改写字幕"))
        XCTAssertTrue(prompt.contains("预期 ID：[1]"))
    }

    func testManualSessionStorePersistsAndClearsProgress() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Movie.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("movie".utf8).write(to: input)
        let store = ManualSessionStore(rootURL: root.appendingPathComponent("Jobs", isDirectory: true))
        let session = ManualTranslationSession(document: document(3), chunkSize: 2)

        try await store.save(session, input: input, trackIndex: 8)
        let loaded = try await store.load(input: input, trackIndex: 8, chunkSize: 2)
        XCTAssertEqual(loaded, session)
        try await store.clear(input: input, trackIndex: 8, chunkSize: 2)
        let cleared = try await store.load(input: input, trackIndex: 8, chunkSize: 2)
        XCTAssertNil(cleared)
    }

    func testManualProgressIsIsolatedByLanguagePair() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualLanguageStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("Movie.mkv")
        try Data("movie".utf8).write(to: input)
        let store = ManualSessionStore(rootURL: root.appendingPathComponent("Jobs"))
        let session = ManualTranslationSession(document: document(2), chunkSize: 2)
        try await store.save(
            session,
            input: input,
            trackIndex: 3,
            sourceLanguage: .english,
            targetLanguage: .french
        )
        let french = try await store.load(
            input: input,
            trackIndex: 3,
            chunkSize: 2,
            sourceLanguage: .english,
            targetLanguage: .french
        )
        let japanese = try await store.load(
            input: input,
            trackIndex: 3,
            chunkSize: 2,
            sourceLanguage: .english,
            targetLanguage: .japanese
        )
        XCTAssertNotNil(french)
        XCTAssertNil(japanese)
    }

    func testManualProgressIsIsolatedForSameNamedFilesInDifferentDirectories() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManualPathIsolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("A", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("Movie.mkv")
        let second = secondDirectory.appendingPathComponent("Movie.mkv")
        try Data("same-size".utf8).write(to: first)
        try Data("same-size".utf8).write(to: second)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: second.path)

        let store = ManualSessionStore(rootURL: root.appendingPathComponent("Jobs", isDirectory: true))
        let firstSession = ManualTranslationSession(document: document(2), chunkSize: 2)
        let secondSession = ManualTranslationSession(document: document(3), chunkSize: 2)
        try await store.save(firstSession, input: first, trackIndex: 3)
        try await store.save(secondSession, input: second, trackIndex: 3)

        let firstLoaded = try await store.load(input: first, trackIndex: 3, chunkSize: 2)
        let secondLoaded = try await store.load(input: second, trackIndex: 3, chunkSize: 2)
        XCTAssertEqual(firstLoaded, firstSession)
        XCTAssertEqual(secondLoaded, secondSession)
    }
}

private final class ManualFormatCheckExecutor: ProcessExecuting, @unchecked Sendable {
    private(set) var standardInput: Data?

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        self.standardInput = standardInput
        return ProcessResult(
            status: 0,
            standardOutput: #"{"type":"item.completed","item":{"type":"agent_message","text":"{\"valid\":true,\"issues\":[]}"}}"#,
            standardError: ""
        )
    }
}
