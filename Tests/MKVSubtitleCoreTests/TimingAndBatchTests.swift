import XCTest
@testable import MKVSubtitleCore

final class TimingAndBatchTests: XCTestCase {
    func testCoordinatorPartialResultsProducePhaseAndOverallETA() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = JobTimingEstimator()
        estimator.start(at: start)
        estimator.update(PipelineProgress(
            phase: .translating, completedChunks: 0, totalChunks: 1,
            completedItems: 0, totalItems: 1_344
        ), at: start)
        let partial = PipelineProgress(
            phase: .translating, completedChunks: 0, totalChunks: 1,
            completedItems: 893, totalItems: 1_344
        )
        let now = start.addingTimeInterval(623)
        estimator.update(partial, at: now)
        let phase = try XCTUnwrap(estimator.estimatedRemaining(at: now))
        let seconds = 623.0 * 451 / 893
        XCTAssertEqual(phase.lowerBound, seconds * 0.65, accuracy: 0.001)
        XCTAssertEqual(phase.upperBound, seconds * 1.35 + 5, accuracy: 0.001)

        let overall = try XCTUnwrap(OverallWorkflowTimingEstimator().estimatedRemaining(
            progress: partial, currentPhaseRemaining: phase,
            translationProfile: .codexLuna, chunkSize: 200,
            mediaDurationSeconds: nil, usesOCR: false,
            deliveryMode: .sidecarSRT, inputFileSizeBytes: nil, usesSubagents: true
        ))
        XCTAssertEqual(overall.lowerBound, phase.lowerBound + 1, accuracy: 0.001)
        XCTAssertEqual(overall.upperBound, phase.upperBound + 10, accuracy: 0.001)
    }

    func testRestoredItemsAreNotCountedAsNewTranslationSpeed() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = JobTimingEstimator()
        estimator.update(PipelineProgress(
            phase: .extracting, completedChunks: 0, totalChunks: 0
        ), at: start.addingTimeInterval(-600))
        let restored = PipelineProgress(
            phase: .translating, completedChunks: 0, totalChunks: 1,
            completedItems: 800, totalItems: 1_000
        )
        estimator.update(restored, at: start)
        estimator.update(restored, at: start.addingTimeInterval(30))
        XCTAssertNil(estimator.estimatedRemaining(at: start.addingTimeInterval(30)))
        estimator.update(PipelineProgress(
            phase: .translating, completedChunks: 0, totalChunks: 1,
            completedItems: 900, totalItems: 1_000
        ), at: start.addingTimeInterval(60))
        let result = try XCTUnwrap(estimator.estimatedRemaining(at: start.addingTimeInterval(60)))
        XCTAssertEqual(result.lowerBound, 60 * 0.65, accuracy: 0.001)
        XCTAssertEqual(result.upperBound, 60 * 1.35 + 5, accuracy: 0.001)

        // A stalled/retrying worker must not make the estimate count down to zero.
        let stalled = try XCTUnwrap(estimator.estimatedRemaining(at: start.addingTimeInterval(120)))
        XCTAssertGreaterThan(stalled.upperBound, result.upperBound)
    }

    func testTranslationETAUsesItemCountsForUnequalBatchesAndResetsBetweenJobs() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = JobTimingEstimator()
        estimator.update(PipelineProgress(
            phase: .translating, completedChunks: 0, totalChunks: 2,
            completedItems: 0, totalItems: 1_000
        ), at: start)
        estimator.update(PipelineProgress(
            phase: .translating, completedChunks: 1, totalChunks: 2,
            completedItems: 900, totalItems: 1_000
        ), at: start.addingTimeInterval(90))
        let result = try XCTUnwrap(estimator.estimatedRemaining(at: start.addingTimeInterval(90)))
        XCTAssertEqual(result.lowerBound, 6.5, accuracy: 0.001)
        estimator.update(PipelineProgress(
            phase: .translating, completedChunks: 2, totalChunks: 2,
            completedItems: 1_000, totalItems: 1_000
        ), at: start.addingTimeInterval(100))
        XCTAssertNil(estimator.estimatedRemaining(at: start.addingTimeInterval(100)))
        estimator.start(at: start.addingTimeInterval(200))
        XCTAssertNil(estimator.estimatedRemaining(at: start.addingTimeInterval(200)))
    }

    func testChunkOnlyProgressStillProducesETA() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var estimator = JobTimingEstimator()
        estimator.update(PipelineProgress(phase: .translating, completedChunks: 2, totalChunks: 4), at: start)
        estimator.update(PipelineProgress(phase: .translating, completedChunks: 3, totalChunks: 4), at: start.addingTimeInterval(60))
        let result = try XCTUnwrap(estimator.estimatedRemaining(at: start.addingTimeInterval(60)))
        XCTAssertEqual(result.lowerBound, 39, accuracy: 0.001)
    }

    func testCoordinatorDoesNotUseSerialBatchHeuristicsBeforeMeasuredProgress() {
        let estimator = OverallWorkflowTimingEstimator()
        for phase in [PipelineProgress.Phase.extracting, .ocr, .translating] {
            XCTAssertNil(estimator.estimatedRemaining(
                progress: PipelineProgress(phase: phase, completedChunks: 0, totalChunks: 1),
                currentPhaseRemaining: nil, translationProfile: .codexLuna,
                chunkSize: 200, mediaDurationSeconds: nil, usesOCR: false,
                deliveryMode: .sidecarSRT, inputFileSizeBytes: nil, usesSubagents: true
            ))
        }
        XCTAssertNotNil(estimator.estimatedRemaining(
            progress: PipelineProgress(phase: .writingSubtitle, completedChunks: 1, totalChunks: 1),
            currentPhaseRemaining: nil, translationProfile: .codexLuna,
            chunkSize: 200, mediaDurationSeconds: nil, usesOCR: false,
            deliveryMode: .sidecarSRT, inputFileSizeBytes: nil, usesSubagents: true
        ))
    }

    func testFolderScanHonorsCancellationBeforeEnumeration() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MKVFolderScanner().scan(FileManager.default.temporaryDirectory)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled scan must stop")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
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
