import Foundation
import WhisperBridge

public struct SpeechRecognitionProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case extractingAudio
        case loadingModel
        case recognizing
        case writing
    }

    public let phase: Phase
    public let fraction: Double
    public let detail: String

    public init(phase: Phase, fraction: Double, detail: String) {
        self.phase = phase
        self.fraction = min(1, max(0, fraction))
        self.detail = detail
    }
}

public final class WhisperTranscriber: @unchecked Sendable {
    private let chunkDurationSeconds = 5 * 60

    public init() {}

    public func transcribe(
        rawPCMURL: URL,
        modelURL: URL,
        prompt: String,
        progress: @escaping @Sendable (SpeechRecognitionProgress) -> Void
    ) async throws -> SubtitleDocument {
        let cancellation = WhisperCancellationBox()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                progress(.init(phase: .loadingModel, fraction: 0, detail: "正在载入 Whisper 模型"))
                let threadCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
                let context = modelURL.path.withCString { path in
                    avc_whisper_create(path, true, Int32(threadCount))
                }
                guard let context else {
                    throw AppError.speechRecognition("Whisper 模型无法载入。请删除模型后重新下载，或改用较小模型。")
                }
                cancellation.set(context)
                defer {
                    cancellation.clear()
                    avc_whisper_destroy(context)
                }

                let fileSize = try rawPCMURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize >= MemoryLayout<Float>.size else {
                    throw AppError.speechRecognition("所选音轨没有可识别的音频数据。")
                }
                let bytesPerChunk = self.chunkDurationSeconds * 16_000 * MemoryLayout<Float>.size
                let totalChunks = max(1, Int(ceil(Double(fileSize) / Double(bytesPerChunk))))
                let handle = try FileHandle(forReadingFrom: rawPCMURL)
                defer { try? handle.close() }
                let collector = WhisperCallbackCollector(progress: progress, totalChunks: totalChunks)
                let opaque = Unmanaged.passUnretained(collector).toOpaque()
                var chunkIndex = 0
                var chunkStartMilliseconds: Int64 = 0

                while let data = try handle.read(upToCount: bytesPerChunk), !data.isEmpty {
                    try Task.checkCancellation()
                    let usableBytes = data.count - data.count % MemoryLayout<Float>.size
                    guard usableBytes > 0 else { break }
                    collector.beginChunk(index: chunkIndex, startMilliseconds: chunkStartMilliseconds)
                    let status: Int32 = prompt.withCString { promptPointer in
                        data.withUnsafeBytes { bytes in
                            let samples = bytes.bindMemory(to: Float.self)
                            return avc_whisper_transcribe(
                                context,
                                samples.baseAddress,
                                Int32(usableBytes / MemoryLayout<Float>.size),
                                promptPointer,
                                whisperProgressThunk,
                                whisperSegmentThunk,
                                opaque
                            )
                        }
                    }
                    if status == 2 || Task.isCancelled { throw CancellationError() }
                    guard status == 0 else {
                        throw AppError.speechRecognition("Whisper 在第 \(chunkIndex + 1) 个音频分段识别失败。")
                    }
                    chunkIndex += 1
                    chunkStartMilliseconds += Int64(usableBytes / MemoryLayout<Float>.size) * 1_000 / 16_000
                }

                let cues = collector.finalizedCues()
                guard !cues.isEmpty else {
                    throw AppError.speechRecognition("没有识别到英文对白。请确认音轨选择正确。")
                }
                progress(.init(phase: .writing, fraction: 0.98, detail: "正在整理时间轴并生成 SRT"))
                return SubtitleDocument(format: .srt, cues: cues)
            }.value
        }, onCancel: {
            cancellation.cancel()
        })
    }
}

private final class WhisperCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?

    func set(_ context: OpaquePointer) {
        lock.lock(); self.context = context; lock.unlock()
    }

    func clear() {
        lock.lock(); context = nil; lock.unlock()
    }

    func cancel() {
        lock.lock(); let value = context; lock.unlock()
        if let value { avc_whisper_cancel(value) }
    }
}

private struct RawWhisperSegment {
    let start: Int64
    let end: Int64
    let text: String
}

private final class WhisperCallbackCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (SpeechRecognitionProgress) -> Void
    private let totalChunks: Int
    private var currentChunk = 0
    private var chunkStartMilliseconds: Int64 = 0
    private var segments: [RawWhisperSegment] = []

    init(progress: @escaping @Sendable (SpeechRecognitionProgress) -> Void, totalChunks: Int) {
        self.progress = progress
        self.totalChunks = max(1, totalChunks)
    }

    func beginChunk(index: Int, startMilliseconds: Int64) {
        lock.lock()
        currentChunk = index
        chunkStartMilliseconds = startMilliseconds
        lock.unlock()
    }

    func report(_ value: Int32) {
        lock.lock(); let index = currentChunk; lock.unlock()
        let fraction = (Double(index) + Double(value) / 100) / Double(totalChunks)
        progress(.init(
            phase: .recognizing,
            fraction: fraction,
            detail: "本地识别第 \(index + 1)/\(totalChunks) 个音频分段"
        ))
    }

    func append(start: Int64, end: Int64, textPointer: UnsafePointer<CChar>?) {
        guard let textPointer else { return }
        let text = String(cString: textPointer).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        let offset = chunkStartMilliseconds
        segments.append(.init(start: offset + start, end: offset + end, text: text))
        lock.unlock()
    }

    func finalizedCues() -> [SubtitleCue] {
        lock.lock(); let values = segments; lock.unlock()
        var cues: [SubtitleCue] = []
        for value in values.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
            if let last = cues.last,
               last.text.caseInsensitiveCompare(value.text) == .orderedSame,
               value.start - last.endMilliseconds < 1_500 {
                continue
            }
            var start = max(0, value.start)
            var end = max(start + 500, value.end)
            if let previous = cues.last, start < previous.endMilliseconds {
                if start > previous.startMilliseconds + 200 {
                    cues[cues.count - 1].endMilliseconds = start
                } else {
                    start = previous.endMilliseconds
                    end = max(start + 500, end)
                }
            }
            cues.append(SubtitleCue(
                id: cues.count + 1,
                startMilliseconds: start,
                endMilliseconds: end,
                text: Self.wrap(value.text)
            ))
        }
        return cues
    }

    private static func wrap(_ text: String) -> String {
        guard text.count > 42, !text.contains("\n") else { return text }
        let words = text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return text }
        let target = text.count / 2
        var first: [String] = []
        var second: [String] = []
        var length = 0
        for word in words {
            if length < target || first.isEmpty {
                first.append(word)
                length += word.count + (first.count > 1 ? 1 : 0)
            } else {
                second.append(word)
            }
        }
        return second.isEmpty ? text : first.joined(separator: " ") + "\n" + second.joined(separator: " ")
    }
}

private let whisperProgressThunk: @convention(c) (Int32, UnsafeMutableRawPointer?) -> Void = { value, pointer in
    guard let pointer else { return }
    Unmanaged<WhisperCallbackCollector>.fromOpaque(pointer).takeUnretainedValue().report(value)
}

private let whisperSegmentThunk: @convention(c) (
    Int64,
    Int64,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void = { start, end, text, pointer in
    guard let pointer else { return }
    Unmanaged<WhisperCallbackCollector>.fromOpaque(pointer).takeUnretainedValue()
        .append(start: start, end: end, textPointer: text)
}
