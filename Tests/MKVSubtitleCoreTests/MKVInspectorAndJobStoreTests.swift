import XCTest
@testable import MKVSubtitleCore

final class MKVInspectorAndJobStoreTests: XCTestCase {
    func testFFprobeJSONProducesDetailedSubtitleTracks() async throws {
        let json = """
        {
          "streams": [
            {"index":0,"codec_name":"hevc","codec_type":"video"},
            {"index":1,"codec_name":"eac3","codec_type":"audio","channels":6,"tags":{"language":"eng","title":"English Atmos"},"disposition":{"default":1,"forced":0,"hearing_impaired":0}},
            {"index":4,"codec_name":"subrip","codec_type":"subtitle","tags":{"language":"eng","title":"English SDH"},"disposition":{"default":1,"forced":0,"hearing_impaired":1}},
            {"index":7,"codec_name":"hdmv_pgs_subtitle","codec_type":"subtitle","tags":{"language":"jpn","title":"PGS"},"disposition":{"default":0,"forced":1,"hearing_impaired":0}}
          ],
          "format":{"duration":"7260.5","tags":{"title":"Arrival"}}
        }
        """
        let executor = InspectorExecutor(result: ProcessResult(status: 0, standardOutput: json, standardError: ""))
        let input = URL(fileURLWithPath: "/tmp/Arrival.mkv")
        let info = try await MKVInspector(ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe"), executor: executor).inspect(input)
        XCTAssertEqual(info.containerTitle, "Arrival")
        XCTAssertEqual(info.durationSeconds, 7_260.5)
        XCTAssertEqual(info.subtitleTracks.count, 2)
        XCTAssertEqual(info.audioTracks, [
            AudioTrack(streamIndex: 1, codec: "eac3", language: "eng", title: "English Atmos", channels: 6, isDefault: true)
        ])
        XCTAssertEqual(info.subtitleTracks[0], SubtitleTrack(streamIndex: 4, codec: "subrip", language: "eng", title: "English SDH", isDefault: true, isForced: false, isSDH: true, isText: true))
        XCTAssertFalse(info.subtitleTracks[1].isText)
        XCTAssertTrue(info.subtitleTracks[1].isForced)
        XCTAssertTrue(info.containsUnsupportedImageSubtitles)
        XCTAssertEqual(executor.arguments.last, input.path)
    }

    func testJobStorePersistsAndClearsCompletedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JobStoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("movie.mkv")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: input)
        let store = JobStore(rootURL: root.appendingPathComponent("records"))
        let record = TranslationJobRecord(
            inputPath: input.path,
            trackIndex: 3,
            translatedItems: [1: "你好"],
            glossary: [GlossaryEntry(source: "John", target: "约翰")],
            completedChunkIndexes: [0]
        )
        try await store.save(record, input: input)
        let loaded = try await store.load(input: input, trackIndex: 3)
        XCTAssertEqual(loaded?.translatedItems, [1: "你好"])
        XCTAssertEqual(loaded?.completedChunkIndexes, [0])
        try await store.clear(input: input, trackIndex: 3)
        let cleared = try await store.load(input: input, trackIndex: 3)
        XCTAssertNil(cleared)
    }

    func testLongSimilarFileNamesDoNotCollideInJobStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JobStoreCollision-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sharedPrefix = String(repeating: "a", count: 190)
        let first = root.appendingPathComponent(sharedPrefix + "-one.mkv")
        let second = root.appendingPathComponent(sharedPrefix + "-two.mkv")
        try Data("same".utf8).write(to: first)
        try Data("same".utf8).write(to: second)
        let store = JobStore(rootURL: root.appendingPathComponent("records"))
        try await store.save(TranslationJobRecord(inputPath: first.path, trackIndex: 1, translatedItems: [1: "first"]), input: first)
        try await store.save(TranslationJobRecord(inputPath: second.path, trackIndex: 1, translatedItems: [1: "second"]), input: second)
        let firstLoaded = try await store.load(input: first, trackIndex: 1)
        let secondLoaded = try await store.load(input: second, trackIndex: 1)
        XCTAssertEqual(firstLoaded?.translatedItems[1], "first")
        XCTAssertEqual(secondLoaded?.translatedItems[1], "second")
    }

    func testSameNamedFilesInDifferentDirectoriesDoNotShareJobProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JobStorePathIsolation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstDirectory = root.appendingPathComponent("First", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("Movie.mkv")
        let second = secondDirectory.appendingPathComponent("Movie.mkv")
        try Data("same-size".utf8).write(to: first)
        try Data("same-size".utf8).write(to: second)
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: first.path)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: second.path)

        let store = JobStore(rootURL: root.appendingPathComponent("records", isDirectory: true))
        try await store.save(
            TranslationJobRecord(inputPath: first.path, trackIndex: 2, translatedItems: [1: "first"]),
            input: first
        )
        try await store.save(
            TranslationJobRecord(inputPath: second.path, trackIndex: 2, translatedItems: [1: "second"]),
            input: second
        )

        let firstLoaded = try await store.load(input: first, trackIndex: 2)
        let secondLoaded = try await store.load(input: second, trackIndex: 2)
        XCTAssertEqual(firstLoaded?.translatedItems[1], "first")
        XCTAssertEqual(secondLoaded?.translatedItems[1], "second")
    }
}

private final class InspectorExecutor: ProcessExecuting, @unchecked Sendable {
    let result: ProcessResult
    var arguments: [String] = []
    init(result: ProcessResult) { self.result = result }
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        self.arguments = arguments
        return result
    }
}
