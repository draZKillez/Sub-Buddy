import XCTest
@testable import MKVSubtitleCore

final class TimingAndBatchTests: XCTestCase {
    func testTranslationETAUsesCompletedChunksAndReturnsRange() {
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = JobTimingEstimator()
        estimator.start(at: start)
        estimator.update(PipelineProgress(
            phase: .translating,
            completedChunks: 0,
            totalChunks: 4,
            completedItems: 0,
            totalItems: 2_000
        ), at: start)
        XCTAssertNil(estimator.estimatedRemaining(at: start.addingTimeInterval(20)))

        estimator.update(PipelineProgress(
            phase: .translating,
            completedChunks: 1,
            totalChunks: 4,
            completedItems: 500,
            totalItems: 2_000
        ), at: start.addingTimeInterval(60))
        let estimate = estimator.estimatedRemaining(at: start.addingTimeInterval(60))
        XCTAssertNotNil(estimate)
        XCTAssertLessThan(estimate!.lowerBound, estimate!.upperBound)
        XCTAssertGreaterThan(estimate!.lowerBound, 100)
    }

    func testCompletionFreezesElapsedTime() {
        let start = Date(timeIntervalSince1970: 2_000)
        var estimator = JobTimingEstimator()
        estimator.start(at: start)
        estimator.update(PipelineProgress(phase: .completed, completedChunks: 1, totalChunks: 1), at: start.addingTimeInterval(90))
        XCTAssertEqual(estimator.elapsed(at: start.addingTimeInterval(500)), 90, accuracy: 0.001)
        XCTAssertEqual(estimator.completedAt, start.addingTimeInterval(90))
    }

    func testOverallEstimateAddsUnstartedTranslationAndWritingToCurrentExtraction() throws {
        let estimator = OverallWorkflowTimingEstimator()
        let phase = EstimatedDurationRange(lowerBound: 40, upperBound: 80)
        let result = try XCTUnwrap(estimator.estimatedRemaining(
            progress: PipelineProgress(
                phase: .extracting,
                completedChunks: 0,
                totalChunks: 0,
                phaseFraction: 0.25
            ),
            currentPhaseRemaining: phase,
            translationProfile: .codexLuna,
            chunkSize: 500,
            mediaDurationSeconds: 7_200,
            usesOCR: false,
            deliveryMode: .sidecarSRT,
            inputFileSizeBytes: 20_000_000_000
        ))

        XCTAssertGreaterThan(result.lowerBound, phase.lowerBound)
        XCTAssertGreaterThan(result.upperBound, phase.upperBound + 500)
    }

    func testOverallEstimateUsesMeasuredTranslationRangeOnceAvailable() throws {
        let estimator = OverallWorkflowTimingEstimator()
        let measured = EstimatedDurationRange(lowerBound: 100, upperBound: 180)
        let result = try XCTUnwrap(estimator.estimatedRemaining(
            progress: PipelineProgress(
                phase: .translating,
                completedChunks: 2,
                totalChunks: 4,
                completedItems: 1_000,
                totalItems: 2_000
            ),
            currentPhaseRemaining: measured,
            translationProfile: .codexSol,
            chunkSize: 500,
            mediaDurationSeconds: 7_200,
            usesOCR: false,
            deliveryMode: .sidecarSRT,
            inputFileSizeBytes: nil
        ))

        XCTAssertEqual(result.lowerBound, 101, accuracy: 0.001)
        XCTAssertEqual(result.upperBound, 190, accuracy: 0.001)
    }

    func testManualEstimateLearnsFromObservedBatchTimesAndKeepsBroadRange() {
        let estimator = OverallWorkflowTimingEstimator()
        let initial = estimator.estimatedManualRemaining(
            remainingChunks: 3,
            observedChunkDurations: [],
            deliveryMode: .sidecarSRT,
            inputFileSizeBytes: nil
        )
        let measured = estimator.estimatedManualRemaining(
            remainingChunks: 3,
            observedChunkDurations: [100, 120, 110],
            deliveryMode: .sidecarSRT,
            inputFileSizeBytes: nil
        )

        XCTAssertGreaterThan(initial.upperBound, measured.upperBound)
        XCTAssertGreaterThan(measured.upperBound, measured.lowerBound)
        XCTAssertGreaterThan(measured.lowerBound, 200)
    }

    func testOverallEstimateIncludesFileSizeSensitiveMuxRange() throws {
        let estimator = OverallWorkflowTimingEstimator()
        let result = try XCTUnwrap(estimator.estimatedRemaining(
            progress: PipelineProgress(
                phase: .writingSubtitle,
                completedChunks: 4,
                totalChunks: 4
            ),
            currentPhaseRemaining: .init(lowerBound: 2, upperBound: 5),
            translationProfile: .codexLuna,
            chunkSize: 500,
            mediaDurationSeconds: nil,
            usesOCR: false,
            deliveryMode: .muxMKV,
            inputFileSizeBytes: 20_000_000_000
        ))

        XCTAssertGreaterThan(result.lowerBound, 20)
        XCTAssertGreaterThan(result.upperBound, 800)
    }

    func testFolderScannerRecursesSortsAndSkipsGeneratedMKVs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderScan-\(UUID())", isDirectory: true)
        let nested = root.appendingPathComponent("Season", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: nested.appendingPathComponent("B.mkv"))
        try Data().write(to: root.appendingPathComponent("A.MKV"))
        try Data().write(to: root.appendingPathComponent("A_zh.mkv"))
        try Data().write(to: root.appendingPathComponent("A_fr.mkv"))
        try Data().write(to: root.appendingPathComponent("A_ja_bilingual.mkv"))
        try Data().write(to: root.appendingPathComponent("Documentary_en.mkv"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))

        let result = try MKVFolderScanner().scan(root)
        XCTAssertEqual(result.map(\.lastPathComponent), ["A.MKV", "Documentary_en.mkv", "B.mkv"])
    }

    func testBatchQueuePersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchStore-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BatchQueueStore(fileURL: root.appendingPathComponent("queue.json"))
        let jobs = [BatchJob(inputPath: "/Movies/A.mkv", status: .processing, detail: "第 1 块", progressFraction: 0.25)]
        try await store.save(jobs)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, jobs)
        try await store.clear()
        let cleared = try await store.load()
        XCTAssertEqual(cleared, [])
    }

    func testBatchQueueRejectsOutOfOrderPersistenceMutations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchRevision-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BatchQueueStore(fileURL: root.appendingPathComponent("queue.json"))
        let newest = [BatchJob(inputPath: "/Movies/Newest.mkv")]
        let stale = [BatchJob(inputPath: "/Movies/Stale.mkv")]

        try await store.save(newest, revision: 2)
        try await store.save(stale, revision: 1)
        let loadedNewest = try await store.load()
        XCTAssertEqual(loadedNewest, newest)

        try await store.clear(revision: 4)
        try await store.save(stale, revision: 3)
        let loadedAfterClear = try await store.load()
        XCTAssertEqual(loadedAfterClear, [])
    }
}
