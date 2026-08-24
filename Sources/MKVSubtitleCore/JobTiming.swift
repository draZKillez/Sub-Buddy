import Foundation

public struct EstimatedDurationRange: Equatable, Sendable {
    public let lowerBound: TimeInterval
    public let upperBound: TimeInterval

    public init(lowerBound: TimeInterval, upperBound: TimeInterval) {
        self.lowerBound = max(0, lowerBound)
        self.upperBound = max(self.lowerBound, upperBound)
    }
}

public struct JobTimingEstimator: Sendable {
    public private(set) var startedAt: Date?
    public private(set) var completedAt: Date?
    private var phaseStartedAt: Date?
    private var currentPhase: PipelineProgress.Phase?
    private var translationBaselineChunks = 0
    private var latestProgress: PipelineProgress?

    public init() {}

    public mutating func start(at date: Date = Date()) {
        startedAt = date
        completedAt = nil
        phaseStartedAt = date
        currentPhase = nil
        translationBaselineChunks = 0
        latestProgress = nil
    }

    public mutating func update(_ progress: PipelineProgress, at date: Date = Date()) {
        if startedAt == nil { start(at: date) }
        if currentPhase != progress.phase {
            currentPhase = progress.phase
            phaseStartedAt = date
            if progress.phase == .translating {
                translationBaselineChunks = progress.completedChunks
            }
        }
        latestProgress = progress
        if progress.phase == .completed { completedAt = date }
    }

    public mutating func finish(at date: Date = Date()) {
        if startedAt != nil, completedAt == nil { completedAt = date }
    }

    public func elapsed(at date: Date = Date()) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (completedAt ?? date).timeIntervalSince(startedAt))
    }

    public func estimatedRemaining(at date: Date = Date()) -> EstimatedDurationRange? {
        guard completedAt == nil,
              let progress = latestProgress,
              let phaseStartedAt else { return nil }
        let phaseElapsed = max(0.1, date.timeIntervalSince(phaseStartedAt))
        let seconds: TimeInterval?

        switch progress.phase {
        case .extracting, .ocr, .muxing:
            guard let fraction = progress.phaseFraction, fraction >= 0.05, fraction < 1 else { return nil }
            seconds = phaseElapsed * (1 - fraction) / fraction
        case .translating:
            let measuredChunks = progress.completedChunks - translationBaselineChunks
            let remainingChunks = max(0, progress.totalChunks - progress.completedChunks)
            guard measuredChunks > 0, remainingChunks > 0 else { return nil }
            seconds = phaseElapsed / Double(measuredChunks) * Double(remainingChunks)
        case .writingSubtitle:
            seconds = 5
        case .completed:
            return nil
        }

        guard let seconds, seconds.isFinite else { return nil }
        // Network/model load varies more than local extraction and muxing, so
        // deliberately present a range rather than false minute-level precision.
        let spread = progress.phase == .translating ? 0.35 : 0.20
        return EstimatedDurationRange(
            lowerBound: max(1, seconds * (1 - spread)),
            upperBound: max(2, seconds * (1 + spread) + 5)
        )
    }
}

public enum TranslationTimingProfile: Sendable {
    case codexLuna
    case codexTerra
    case codexSol
    case appleLocal
    case manual

    fileprivate var secondsPerChunk: EstimatedDurationRange {
        switch self {
        case .codexLuna:
            return .init(lowerBound: 20, upperBound: 240)
        case .codexTerra:
            return .init(lowerBound: 30, upperBound: 360)
        case .codexSol:
            return .init(lowerBound: 45, upperBound: 600)
        case .appleLocal:
            return .init(lowerBound: 3, upperBound: 90)
        case .manual:
            return .init(lowerBound: 60, upperBound: 600)
        }
    }
}

/// Produces a deliberately broad whole-workflow range. The current phase uses
/// measured progress; phases that have not started use transparent, conservative
/// bounds and are replaced by measured values as soon as data becomes available.
public struct OverallWorkflowTimingEstimator: Sendable {
    public init() {}

    public func estimatedRemaining(
        progress: PipelineProgress,
        currentPhaseRemaining: EstimatedDurationRange?,
        translationProfile: TranslationTimingProfile,
        chunkSize: Int,
        mediaDurationSeconds: Double?,
        usesOCR: Bool,
        deliveryMode: DeliveryMode,
        inputFileSizeBytes: Int64?
    ) -> EstimatedDurationRange? {
        guard progress.phase != .completed else { return nil }
        let boundedChunkSize = max(1, chunkSize)
        var ranges: [EstimatedDurationRange] = []

        switch progress.phase {
        case .extracting:
            guard let currentPhaseRemaining else { return nil }
            ranges.append(currentPhaseRemaining)
            let cueRange = estimatedCueCount(mediaDurationSeconds: mediaDurationSeconds)
            if usesOCR { ranges.append(ocrRange(cueRange: cueRange)) }
            ranges.append(translationRange(
                minimumCueCount: cueRange.lowerBound,
                maximumCueCount: cueRange.upperBound,
                chunkSize: boundedChunkSize,
                profile: translationProfile
            ))
            ranges.append(postProcessingRange(deliveryMode: deliveryMode, inputFileSizeBytes: inputFileSizeBytes))

        case .ocr:
            guard let currentPhaseRemaining else { return nil }
            ranges.append(currentPhaseRemaining)
            let cueRange = progress.totalItems > 0
                ? progress.totalItems...progress.totalItems
                : estimatedCueCount(mediaDurationSeconds: mediaDurationSeconds)
            ranges.append(translationRange(
                minimumCueCount: cueRange.lowerBound,
                maximumCueCount: cueRange.upperBound,
                chunkSize: boundedChunkSize,
                profile: translationProfile
            ))
            ranges.append(postProcessingRange(deliveryMode: deliveryMode, inputFileSizeBytes: inputFileSizeBytes))

        case .translating:
            let remainingChunks = max(0, progress.totalChunks - progress.completedChunks)
            if remainingChunks > 0 {
                ranges.append(currentPhaseRemaining ?? translationRange(
                    chunkCount: remainingChunks,
                    profile: translationProfile
                ))
            }
            ranges.append(postProcessingRange(deliveryMode: deliveryMode, inputFileSizeBytes: inputFileSizeBytes))

        case .writingSubtitle:
            ranges.append(currentPhaseRemaining ?? .init(lowerBound: 1, upperBound: 10))
            if deliveryMode == .muxMKV {
                ranges.append(muxRange(inputFileSizeBytes: inputFileSizeBytes))
            }

        case .muxing:
            ranges.append(currentPhaseRemaining ?? muxRange(inputFileSizeBytes: inputFileSizeBytes))

        case .completed:
            return nil
        }

        return sum(ranges)
    }

    public func estimatedManualRemaining(
        remainingChunks: Int,
        observedChunkDurations: [TimeInterval],
        deliveryMode: DeliveryMode,
        inputFileSizeBytes: Int64?
    ) -> EstimatedDurationRange {
        let chunks = max(0, remainingChunks)
        let translation: EstimatedDurationRange
        if chunks == 0 {
            translation = .init(lowerBound: 0, upperBound: 0)
        } else if !observedChunkDurations.isEmpty {
            let recent = observedChunkDurations.suffix(5).map { max(1, $0) }.sorted()
            let median = recent[recent.count / 2]
            translation = .init(
                lowerBound: max(15, median * 0.65) * Double(chunks),
                upperBound: max(60, median * 1.75 + 30) * Double(chunks)
            )
        } else {
            translation = translationRange(chunkCount: chunks, profile: .manual)
        }
        return sum([
            translation,
            postProcessingRange(deliveryMode: deliveryMode, inputFileSizeBytes: inputFileSizeBytes)
        ])
    }

    private func estimatedCueCount(mediaDurationSeconds: Double?) -> ClosedRange<Int> {
        guard let mediaDurationSeconds, mediaDurationSeconds > 0 else { return 200...4_000 }
        let minutes = mediaDurationSeconds / 60
        let lower = max(1, Int((minutes * 3).rounded(.up)))
        let upper = max(lower, Int((minutes * 22).rounded(.up)))
        return lower...upper
    }

    private func ocrRange(cueRange: ClosedRange<Int>) -> EstimatedDurationRange {
        .init(
            lowerBound: max(5, Double(cueRange.lowerBound) * 0.03),
            upperBound: max(30, Double(cueRange.upperBound) * 0.8 + 30)
        )
    }

    private func translationRange(
        minimumCueCount: Int,
        maximumCueCount: Int,
        chunkSize: Int,
        profile: TranslationTimingProfile
    ) -> EstimatedDurationRange {
        let minimumChunks = max(1, Int(ceil(Double(minimumCueCount) / Double(chunkSize))))
        let maximumChunks = max(minimumChunks, Int(ceil(Double(maximumCueCount) / Double(chunkSize))))
        let perChunk = profile.secondsPerChunk
        return .init(
            lowerBound: perChunk.lowerBound * Double(minimumChunks),
            upperBound: perChunk.upperBound * Double(maximumChunks)
        )
    }

    private func translationRange(
        chunkCount: Int,
        profile: TranslationTimingProfile
    ) -> EstimatedDurationRange {
        let count = Double(max(0, chunkCount))
        return .init(
            lowerBound: profile.secondsPerChunk.lowerBound * count,
            upperBound: profile.secondsPerChunk.upperBound * count
        )
    }

    private func postProcessingRange(
        deliveryMode: DeliveryMode,
        inputFileSizeBytes: Int64?
    ) -> EstimatedDurationRange {
        let writing = EstimatedDurationRange(lowerBound: 1, upperBound: 10)
        guard deliveryMode == .muxMKV else { return writing }
        return sum([writing, muxRange(inputFileSizeBytes: inputFileSizeBytes)])
    }

    private func muxRange(inputFileSizeBytes: Int64?) -> EstimatedDurationRange {
        guard let inputFileSizeBytes, inputFileSizeBytes > 0 else {
            return .init(lowerBound: 20, upperBound: 900)
        }
        let bytes = Double(inputFileSizeBytes)
        return .init(
            lowerBound: max(5, bytes / 800_000_000),
            upperBound: max(30, bytes / 25_000_000 + 30)
        )
    }

    private func sum(_ ranges: [EstimatedDurationRange]) -> EstimatedDurationRange {
        .init(
            lowerBound: ranges.reduce(0) { $0 + $1.lowerBound },
            upperBound: ranges.reduce(0) { $0 + $1.upperBound }
        )
    }
}
