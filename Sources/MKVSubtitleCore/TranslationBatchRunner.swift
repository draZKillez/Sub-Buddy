import Foundation

/// Bounded waves deliberately share one glossary snapshot. No task can spawn
/// more requests; repairs remain sequential inside each of the two lanes.
struct TranslationBatchRunner: Sendable {
    let provider: TranslationProvider
    let concurrency: Int

    func run(
        chunks: [TranslationChunk], record: TranslationJobRecord,
        movie: MovieInfo, sourceLanguage: SubtitleLanguage, targetLanguage: SubtitleLanguage,
        store: JobStore, input: URL,
        progress: @escaping @Sendable (PipelineProgress) -> Void
    ) async throws -> TranslationJobRecord {
        let checkpoint = TranslationCheckpoint(record: record, chunks: chunks, store: store, input: input, progress: progress)
        let pending = chunks.filter { !record.completedChunkIndexes.contains($0.index) }
        let width = max(1, min(2, concurrency, provider.maximumConcurrentBatches))
        for start in stride(from: 0, to: pending.count, by: width) {
            try Task.checkCancellation()
            let wave = Array(pending[start..<min(start + width, pending.count)])
            let snapshot = await checkpoint.begin(wave)
            let engine = TranslationEngine(provider: provider)
            // Format failures let the companion finish and save. Service,
            // quota, auth, storage failures and cancellation stop both lanes.
            try await withThrowingTaskGroup(of: Void.self) { group in
                for chunk in wave {
                    group.addTask {
                        do {
                            _ = try await engine.translate(
                                chunk: chunk, movie: movie, glossary: snapshot.glossary,
                                sourceLanguage: sourceLanguage, targetLanguage: targetLanguage,
                                completedItems: snapshot.translatedItems,
                                onValidated: { response in
                                    try await checkpoint.accept(response, chunk: chunk)
                                }, onRepair: { await checkpoint.repairing(chunk) }
                            )
                            await checkpoint.finished(chunk)
                        } catch let error as AppError {
                            if case .invalidTranslation = error {
                                await checkpoint.failedFormat(error, chunk: chunk)
                            } else { throw error }
                        }
                    }
                }
                do { for try await _ in group {} }
                catch { group.cancelAll(); throw error }
            }
            try await checkpoint.checkFailure()
        }
        try Task.checkCancellation()
        return await checkpoint.snapshot()
    }
}

private actor TranslationCheckpoint {
    private var record: TranslationJobRecord
    private let chunks: [TranslationChunk]
    private let totalItems: Int
    private let store: JobStore
    private let input: URL
    private let progress: @Sendable (PipelineProgress) -> Void
    private var active: Set<Int> = []
    private var waveBaseGlossary: [GlossaryEntry] = []
    private var waveUpdates: [Int: [GlossaryEntry]] = [:]
    private var failure: AppError?
    // Actor methods can re-enter at an await. Explicitly chaining persistence
    // prevents an older full-record snapshot from overwriting a newer one.
    private var lastSave: Task<Void, Error>?

    init(record: TranslationJobRecord, chunks: [TranslationChunk], store: JobStore, input: URL,
         progress: @escaping @Sendable (PipelineProgress) -> Void) {
        self.record = record
        self.chunks = chunks
        self.totalItems = chunks.reduce(0) { $0 + $1.core.count }
        self.store = store
        self.input = input
        self.progress = progress
    }

    func begin(_ wave: [TranslationChunk]) -> TranslationJobRecord {
        active = Set(wave.map(\.index))
        waveBaseGlossary = record.glossary
        waveUpdates = [:]
        emit()
        return record
    }

    func accept(_ response: TranslationResponse, chunk: TranslationChunk) async throws {
        for item in response.items { record.translatedItems[item.id] = item.text }
        waveUpdates[chunk.index] = TranslationGlossary.merge(waveUpdates[chunk.index] ?? [], response.glossaryUpdates)
        record.glossary = waveUpdates.keys.sorted().reduce(waveBaseGlossary) {
            TranslationGlossary.merge($0, waveUpdates[$1] ?? [])
        }
        if chunk.core.allSatisfy({ record.translatedItems[$0.id] != nil }) {
            record.completedChunkIndexes.insert(chunk.index)
        }
        let snapshot = record
        let previous = lastSave
        let save = Task { [store, input] in
            try await previous?.value
            try await store.save(snapshot, input: input)
        }
        lastSave = save
        try await save.value
        emit()
    }

    func repairing(_ chunk: TranslationChunk) { emit(repairing: chunk.index) }
    func finished(_ chunk: TranslationChunk) { active.remove(chunk.index); emit() }
    func failedFormat(_ error: AppError, chunk: TranslationChunk) {
        if failure == nil { failure = error }
        active.remove(chunk.index)
        emit()
    }
    func checkFailure() async throws {
        try await lastSave?.value
        if let failure { throw failure }
    }
    func snapshot() -> TranslationJobRecord { record }

    private func emit(repairing: Int? = nil) {
        progress(PipelineProgress(
            phase: .translating, completedChunks: record.completedChunkIndexes.count,
            totalChunks: chunks.count, completedItems: record.translatedItems.count, totalItems: totalItems,
            activeChunkIndexes: active.sorted(), repairingChunkIndex: repairing
        ))
    }
}
