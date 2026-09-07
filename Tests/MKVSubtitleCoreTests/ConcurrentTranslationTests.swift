import Foundation
import XCTest
@testable import MKVSubtitleCore

final class ConcurrentTranslationTests: XCTestCase {
    /// Opt-in integration smoke test. Four original, synthetic lines only;
    /// no movie files or credentials are read by the test.
    func testOptInLiveSchemaAndTwoCodexRequests() async throws {
        guard let executable = ProcessInfo.processInfo.environment["SUBBUDDY_BETA_CODEX"] else {
            throw XCTSkip("Set SUBBUDDY_BETA_CODEX to explicitly run the four-line live test.")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveBeta-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Synthetic.mkv")
        let texts = ["Hello, friend.", "<i>Are you ready?</i>", "Open the door.\nCome inside.", "See you tomorrow."]
        let source = texts.enumerated().map { SubtitleCue(id: $0.offset + 1, startMilliseconds: Int64($0.offset * 2000), endMilliseconds: Int64($0.offset * 2000 + 1000), text: $0.element) }
        let provider = CodexTranslationProvider(bridge: CodexBridge(codexURL: URL(fileURLWithPath: executable)))
        let result = try await TranslationBatchRunner(provider: provider, concurrency: 2).run(
            chunks: TranslationChunker(configuration: .init(targetCoreCount: 2, maximumCoreCount: 2)).chunks(for: source),
            record: .init(inputPath: input.path, trackIndex: 2), movie: .init(originalTitle: "Synthetic Test"),
            sourceLanguage: .english, targetLanguage: .simplifiedChinese,
            store: JobStore(rootURL: root), input: input, progress: { _ in }
        )
        XCTAssertEqual(result.translatedItems.count, 4)
        for cue in source {
            XCTAssertTrue(TranslationValidator.preservesFormatting(try XCTUnwrap(result.translatedItems[cue.id]), source: cue.text))
        }
    }

    private func cues(_ count: Int) -> [SubtitleCue] {
        (1...count).map { .init(id: $0, startMilliseconds: Int64($0 * 1000), endMilliseconds: Int64($0 * 1000 + 700), text: "Line \($0)") }
    }

    func testTwoLanesUse200CuesAndSaveEveryItemWithDeterministicGlossary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Concurrent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let input = root.appendingPathComponent("Film.mkv")
        let provider = ConcurrentProvider()
        let chunks = TranslationChunker().chunks(for: cues(600))
        XCTAssertEqual(chunks.map { $0.core.count }, [200, 200, 200])
        let record = try await TranslationBatchRunner(provider: provider, concurrency: 2).run(
            chunks: chunks, record: .init(inputPath: input.path, trackIndex: 2), movie: .init(originalTitle: "Test"),
            sourceLanguage: .english, targetLanguage: .japanese, store: store, input: input, progress: { _ in }
        )
        let stats = await provider.stats()
        XCTAssertEqual(stats.0, 2)
        XCTAssertEqual(stats.1.count, 3)
        XCTAssertEqual(record.translatedItems.count, 600)
        XCTAssertEqual(record.completedChunkIndexes, [0, 1, 2])
        XCTAssertEqual(record.glossary.last?.target, "Term 2")
        let requests = await provider.received
        XCTAssertTrue(requests.filter { $0.chunk.index < 2 }.allSatisfy { $0.glossary.isEmpty })
        XCTAssertEqual(requests.first { $0.chunk.index == 2 }?.glossary.last?.target, "Term 1")
        XCTAssertTrue(requests.allSatisfy { $0.targetLanguage == .japanese })
        let saved = try await store.load(input: input, trackIndex: 2)
        XCTAssertEqual(saved?.translatedItems, record.translatedItems)
    }

    func testFormatFailureKeepsCompanionAndRetryOnlyRequestsRemainingID() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentRetry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JobStore(rootURL: root)
        let input = root.appendingPathComponent("Film.mkv")
        let chunks = TranslationChunker(configuration: .init(targetCoreCount: 2, maximumCoreCount: 2)).chunks(for: cues(4))
        let provider = ConcurrentProvider(invalidID: 1)
        do {
            _ = try await TranslationBatchRunner(provider: provider, concurrency: 2).run(
                chunks: chunks, record: .init(inputPath: input.path, trackIndex: 2), movie: .init(originalTitle: "Test"),
                sourceLanguage: .english, targetLanguage: .simplifiedChinese, store: store, input: input, progress: { _ in }
            )
            XCTFail("Must not report success for missing ID")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1")) }
        let loaded = try await store.load(input: input, trackIndex: 2)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(Set(saved.translatedItems.keys), [2, 3, 4])
        let retry = ConcurrentProvider()
        _ = try await TranslationBatchRunner(provider: retry, concurrency: 2).run(
            chunks: chunks, record: saved, movie: .init(originalTitle: "Test"),
            sourceLanguage: .english, targetLanguage: .simplifiedChinese, store: store, input: input, progress: { _ in }
        )
        let requests = await retry.stats().1
        XCTAssertEqual(requests, [[1]])
    }

    func testQuotaStopsBothLanesAndNeverStartsNextWaveOrRetries() async throws {
        let provider = ConcurrentProvider(quota: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentQuota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Film.mkv")
        do {
            _ = try await TranslationBatchRunner(provider: provider, concurrency: 2).run(
                chunks: TranslationChunker(configuration: .init(targetCoreCount: 1, maximumCoreCount: 1)).chunks(for: cues(6)),
                record: .init(inputPath: input.path, trackIndex: 2), movie: .init(originalTitle: "Test"),
                sourceLanguage: .english, targetLanguage: .french, store: JobStore(rootURL: root), input: input, progress: { _ in }
            )
            XCTFail("Expected quota error")
        } catch let error as AppError { XCTAssertEqual(error, .codexQuotaUnavailable) }
        let stats = await provider.stats()
        XCTAssertLessThanOrEqual(stats.1.count, 2)
        XCTAssertEqual(stats.2, 0)
    }

    func testCancelStopsBothInFlightRequests() async throws {
        let provider = ConcurrentProvider(slow: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentCancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Film.mkv")
        let chunks = TranslationChunker(configuration: .init(targetCoreCount: 1, maximumCoreCount: 1)).chunks(for: cues(4))
        let task = Task {
            try await TranslationBatchRunner(provider: provider, concurrency: 2).run(
                chunks: chunks, record: .init(inputPath: input.path, trackIndex: 2), movie: .init(originalTitle: "Test"),
                sourceLanguage: .english, targetLanguage: .french, store: JobStore(rootURL: root), input: input, progress: { _ in }
            )
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let stats = await provider.stats()
        XCTAssertEqual(stats.0, 2)
        XCTAssertEqual(stats.2, 0)
        XCTAssertEqual(stats.1.count, 2)
    }

    func testFormattingRejectsLostTagsAndCollapsedLinesButKeepsValidItems() throws {
        let source = [SubtitleCue(id: 1, startMilliseconds: 0, endMilliseconds: 1000, text: "<i>First\nSecond</i>"),
                      SubtitleCue(id: 2, startMilliseconds: 1000, endMilliseconds: 2000, text: "Hello")]
        let response = TranslationResponse(items: [
            .init(id: 1, text: "第一第二", source: source[0].text),
            .init(id: 2, text: "你好", source: "Hello")
        ])
        let raw = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let valid = try TranslationValidator().alignedPartial(rawJSON: raw, expectedCues: source, requiresSourceEcho: true)
        XCTAssertEqual(valid.items.map(\.id), [2])
        XCTAssertTrue(TranslationValidator.preservesFormatting("<i>第一\n第二</i>\n", source: source[0].text))
    }

    func testSchemaRestrictsIDsAndForbidsAdditionalFields() throws {
        let data = try TranslationOutputSchema.data(for: cues(200))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["additionalProperties"] as? Bool, false)
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let items = try XCTUnwrap(properties["items"] as? [String: Any])
        let item = try XCTUnwrap(items["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["id", "source", "text"])
        let fields = try XCTUnwrap(item["properties"] as? [String: Any])
        XCTAssertEqual((fields["id"] as? [String: Any])?["enum"] as? [Int], Array(1...200))
        XCTAssertThrowsError(try TranslationOutputSchema.data(for: []))
    }

    func testEmptyExportDoesNotOverwriteExistingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyExport-\(UUID()).srt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("existing".utf8).write(to: url)
        XCTAssertThrowsError(try SubtitleWriter().write(.init(format: .srt, cues: []), to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "existing")
    }

    func testAutomaticSelectionPrefersFullDialogueOverForcedFallback() {
        let forced = SubtitleTrack(streamIndex: 3, codec: "subrip", language: "fre", title: "French (Forced)", isDefault: true, isForced: true, isSDH: false, isText: true)
        let full = SubtitleTrack(streamIndex: 4, codec: "subrip", language: "fre", title: "French", isDefault: false, isForced: false, isSDH: false, isText: true)
        XCTAssertEqual(SubtitleTrack.preferred(in: [forced, full], language: .english), full)
        XCTAssertEqual(SubtitleTrack.preferred(in: [forced, full], language: .french), full)
        XCTAssertEqual(SubtitleTrack.preferred(in: [forced], language: .english), forced)
    }

    func testConcurrentPipelineKeepsTimelineAndOrderWhenResponsesArriveReversed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConcurrentOutput-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Film.mkv")
        let output = root.appendingPathComponent("Film.srt")
        try Data().write(to: input)
        let source = cues(401)
        let provider = ConcurrentProvider()
        let pipeline = TranslationPipeline(
            ffmpeg: FFmpegService(ffmpegURL: URL(fileURLWithPath: "/unused"), executor: ConcurrentExtraction(cues: source)),
            provider: provider, jobStore: JobStore(rootURL: root.appendingPathComponent("Jobs")), maximumConcurrentChunks: 2
        )
        _ = try await pipeline.run(input: input,
            track: .init(streamIndex: 2, codec: "subrip", language: "eng", title: "English", isDefault: false, isForced: false, isSDH: false, isText: true),
            movie: .init(originalTitle: "Test"), output: output, existingSubtitleCount: 1, overwrite: false, progress: { _ in })
        let parsed = try SubtitleParser().parse(contentsOf: output, format: .srt)
        XCTAssertEqual(parsed.cues.map(\.id), source.map(\.id))
        XCTAssertEqual(parsed.cues.map(\.startMilliseconds), source.map(\.startMilliseconds))
        XCTAssertEqual(parsed.cues.map(\.endMilliseconds), source.map(\.endMilliseconds))
        XCTAssertEqual(parsed.cues.map(\.text), source.map { "译文 \($0.id)" })
        let stats = await provider.stats()
        XCTAssertEqual(stats.0, 2)
    }
}

private struct ConcurrentExtraction: ProcessExecuting {
    let cues: [SubtitleCue]
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        try SubtitleWriter().write(.init(format: .srt, cues: cues), to: URL(fileURLWithPath: arguments.last!))
        return .init(status: 0, standardOutput: "", standardError: "")
    }
}

private actor ConcurrentProvider: TranslationProvider {
    nonisolated let requiresSourceEcho = true
    var received: [TranslationRequest] = []
    private var active = 0
    private var maximum = 0
    let invalidID: Int?
    let quota: Bool
    let slow: Bool
    init(invalidID: Int? = nil, quota: Bool = false, slow: Bool = false) {
        self.invalidID = invalidID; self.quota = quota; self.slow = slow
    }
    func stats() -> (Int, [[Int]], Int) { (maximum, received.map { $0.chunk.core.map(\.id) }, active) }
    func translate(_ request: TranslationRequest) async throws -> String {
        received.append(request)
        active += 1; maximum = max(maximum, active)
        defer { active -= 1 }
        if quota && request.chunk.index == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
            throw AppError.codexQuotaUnavailable
        }
        try await Task.sleep(nanoseconds: slow || quota ? 10_000_000_000 : (request.chunk.index == 0 ? 30_000_000 : 10_000_000))
        let items = request.chunk.core.reversed().map {
            TranslationItem(id: $0.id, text: $0.id == invalidID ? "" : "译文 \($0.id)", source: $0.text)
        }
        return String(decoding: try JSONEncoder().encode(TranslationResponse(items: items,
            glossaryUpdates: [.init(source: "Name", target: "Term \(request.chunk.index)")])), as: UTF8.self)
    }
}
