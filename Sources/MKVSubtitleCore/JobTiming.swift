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
