import Foundation

public struct FFmpegArguments: Sendable {
    public init() {}

    public func extraction(input: URL, streamIndex: Int, output: URL, overwrite: Bool = true) -> [String] {
        [
            overwrite ? "-y" : "-n",
            "-v", "error",
            "-nostdin",
            "-nostats",
            "-progress", "pipe:1",
            "-i", input.path,
            "-map", "0:\(streamIndex)",
            "-c:s", "copy",
            output.path
        ]
    }

    public func speechAudioExtraction(input: URL, streamIndex: Int, output: URL) -> [String] {
        [
            "-y", "-v", "error", "-nostdin", "-nostats", "-progress", "pipe:1",
            "-i", input.path,
            "-map", "0:\(streamIndex)",
            "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", "16000",
            "-c:a", "pcm_f32le", "-f", "f32le",
            output.path
        ]
    }

    public func muxing(
        input: URL,
        chineseSubtitle: URL,
        output: URL,
        existingSubtitleCount: Int,
        trackTitle: String = "简体中文",
        languageCode: String = "zho",
        overwrite: Bool
    ) throws -> [String] {
        guard !FileSafety.refersToSameFile(input, output) else { throw AppError.originalOverwriteForbidden }
        return [
            overwrite ? "-y" : "-n",
            "-v", "error",
            "-nostdin",
            "-nostats",
            "-progress", "pipe:1",
            "-i", input.path,
            "-i", chineseSubtitle.path,
            "-map", "0",
            "-map", "1:0",
            "-c", "copy",
            "-metadata:s:s:\(existingSubtitleCount)", "language=\(languageCode)",
            "-metadata:s:s:\(existingSubtitleCount)", "title=\(trackTitle)",
            "-disposition:s:\(existingSubtitleCount)", "0",
            output.path
        ]
    }
}

public struct MKVExtractArguments: Sendable {
    public init() {}

    public func extraction(input: URL, trackID: Int, output: URL) -> [String] {
        ["tracks", input.path, "\(trackID):\(output.path)"]
    }
}

public final class FFmpegService: @unchecked Sendable {
    private let ffmpegURL: URL?
    private let mkvextractURL: URL?
    private let bitmapSubtitleDecoderURL: URL?
    private let executor: ProcessExecuting
    private let argumentBuilder: FFmpegArguments
    private let mkvExtractArgumentBuilder: MKVExtractArguments
    private let fileManager: FileManager

    public init(
        ffmpegURL: URL?,
        mkvextractURL: URL? = nil,
        bitmapSubtitleDecoderURL: URL? = nil,
        executor: ProcessExecuting = ProcessExecutor(),
        argumentBuilder: FFmpegArguments = .init(),
        mkvExtractArgumentBuilder: MKVExtractArguments = .init(),
        fileManager: FileManager = .default
    ) {
        self.ffmpegURL = ffmpegURL
        self.mkvextractURL = mkvextractURL
        self.bitmapSubtitleDecoderURL = bitmapSubtitleDecoderURL
        self.executor = executor
        self.argumentBuilder = argumentBuilder
        self.mkvExtractArgumentBuilder = mkvExtractArgumentBuilder
        self.fileManager = fileManager
    }

    public func extractSubtitle(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        durationSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard track.isText else {
            if MKVInspector.imageSubtitleCodecs.contains(track.codec.lowercased()) {
                throw AppError.unsupportedSubtitle("检测到图片字幕，当前版本暂不支持 OCR。")
            }
            throw AppError.unsupportedSubtitle("当前版本不支持字幕编码：\(track.codec)。")
        }
        try await extractRawSubtitle(
            input: input,
            track: track,
            output: output,
            durationSeconds: durationSeconds,
            progress: progress
        )
    }

    public func extractAudioForSpeechRecognition(
        input: URL,
        track: AudioTrack,
        output: URL,
        durationSeconds: Double?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let ffmpegURL else {
            throw AppError.toolMissing(
                name: "FFmpeg",
                guidance: "内嵌 FFmpeg 未找到，无法提取语音识别音轨。请重新安装最新版 App。"
            )
        }
        let arguments = argumentBuilder.speechAudioExtraction(
            input: input,
            streamIndex: track.streamIndex,
            output: output
        )
        let result: ProcessResult
        if let streamingExecutor = executor as? StreamingProcessExecuting,
           let durationSeconds, durationSeconds > 0 {
            let parser = FFmpegProgressParser(durationSeconds: durationSeconds)
            result = try await streamingExecutor.run(
                executable: ffmpegURL,
                arguments: arguments,
                standardInput: nil
            ) { chunk in
                if let fraction = parser.consume(chunk) { progress(fraction) }
            }
        } else {
            result = try await executor.run(executable: ffmpegURL, arguments: arguments, standardInput: nil)
        }
        guard result.status == 0 else {
            throw AppError.processFailed(tool: "FFmpeg", code: result.status, message: result.standardError)
        }
        progress(1)
    }

    public func extractPGSSubtitle(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        durationSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard track.codec.lowercased() == "hdmv_pgs_subtitle" else {
            throw AppError.unsupportedSubtitle("本地 OCR 第一阶段仅支持 PGS 图片字幕。")
        }
        try await extractRawSubtitle(
            input: input,
            track: track,
            output: output,
            durationSeconds: durationSeconds,
            progress: progress
        )
    }

    public func decodeVobSubSubtitle(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard track.isVobSub else {
            throw AppError.unsupportedSubtitle("所选轨道不是 VobSub/DVD 图片字幕。")
        }
        guard let bitmapSubtitleDecoderURL else {
            throw AppError.toolMissing(
                name: "VobSub 解码组件",
                guidance: "内嵌 VobSub 解码组件未找到。请重新安装最新版 App。"
            )
        }
        let parser = BitmapDecoderProgressParser()
        let arguments = [input.path, String(track.streamIndex), output.path]
        let result: ProcessResult
        if let streamingExecutor = executor as? StreamingProcessExecuting {
            result = try await streamingExecutor.run(
                executable: bitmapSubtitleDecoderURL,
                arguments: arguments,
                standardInput: nil
            ) { chunk in
                if let fraction = parser.consume(chunk) { progress(fraction) }
            }
        } else {
            result = try await executor.run(
                executable: bitmapSubtitleDecoderURL,
                arguments: arguments,
                standardInput: nil
            )
        }
        guard result.status == 0 else {
            throw AppError.processFailed(
                tool: "VobSub 解码组件",
                code: result.status,
                message: result.standardError
            )
        }
        progress(1)
    }

    private func extractRawSubtitle(
        input: URL,
        track: SubtitleTrack,
        output: URL,
        durationSeconds: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        if let mkvextractURL {
            do {
                let arguments = mkvExtractArgumentBuilder.extraction(
                    input: input,
                    trackID: track.streamIndex,
                    output: output
                )
                let result: ProcessResult
                if let streamingExecutor = executor as? StreamingProcessExecuting {
                    let parser = MKVExtractProgressParser()
                    result = try await streamingExecutor.run(
                        executable: mkvextractURL,
                        arguments: arguments,
                        standardInput: nil
                    ) { chunk in
                        if let fraction = parser.consume(chunk) { progress(fraction) }
                    }
                } else {
                    result = try await executor.run(executable: mkvextractURL, arguments: arguments, standardInput: nil)
                }
                if result.status == 0 {
                    progress(1)
                    return
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A malformed/missing Matroska index or track-ID mismatch falls back to FFmpeg.
            }
            progress(0)
        }

        guard let ffmpegURL else {
            throw AppError.toolMissing(
                name: "FFmpeg",
                guidance: "内嵌 FFmpeg 未找到或不可执行。请重新安装本 App；也可运行 brew install ffmpeg 后重新检测。"
            )
        }
        let arguments = argumentBuilder.extraction(input: input, streamIndex: track.streamIndex, output: output)
        let result: ProcessResult
        if let streamingExecutor = executor as? StreamingProcessExecuting, let durationSeconds, durationSeconds > 0 {
            let parser = FFmpegProgressParser(durationSeconds: durationSeconds)
            result = try await streamingExecutor.run(
                executable: ffmpegURL,
                arguments: arguments,
                standardInput: nil
            ) { chunk in
                if let fraction = parser.consume(chunk) { progress(fraction) }
            }
        } else {
            result = try await executor.run(executable: ffmpegURL, arguments: arguments, standardInput: nil)
        }
        guard result.status == 0 else { throw AppError.processFailed(tool: "FFmpeg", code: result.status, message: result.standardError) }
        progress(1)
    }

    public func mux(
        input: URL,
        chineseSubtitle: URL,
        output: URL,
        existingSubtitleCount: Int,
        trackTitle: String = "简体中文",
        languageCode: String = "zho",
        overwrite: Bool,
        durationSeconds: Double? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let ffmpegURL else {
            throw AppError.toolMissing(
                name: "FFmpeg",
                guidance: "内嵌 FFmpeg 未找到或不可执行。请重新安装本 App；也可运行 brew install ffmpeg 后重新检测。"
            )
        }
        guard !FileSafety.refersToSameFile(input, output, fileManager: fileManager) else {
            throw AppError.originalOverwriteForbidden
        }
        let outputExists = fileManager.fileExists(atPath: output.path)
        if outputExists && !overwrite { throw AppError.outputExists(output) }
        let outputExtension = output.pathExtension.isEmpty ? "mkv" : output.pathExtension
        let temporaryOutput = output.deletingLastPathComponent().appendingPathComponent(
            ".mkv-subtitle-translator-\(UUID().uuidString).partial.\(outputExtension)"
        )
        defer { try? fileManager.removeItem(at: temporaryOutput) }
        let arguments = try argumentBuilder.muxing(
            input: input,
            chineseSubtitle: chineseSubtitle,
            output: temporaryOutput,
            existingSubtitleCount: existingSubtitleCount,
            trackTitle: trackTitle,
            languageCode: languageCode,
            overwrite: true
        )
        let result: ProcessResult
        if let streamingExecutor = executor as? StreamingProcessExecuting, let durationSeconds, durationSeconds > 0 {
            let parser = FFmpegProgressParser(durationSeconds: durationSeconds)
            result = try await streamingExecutor.run(
                executable: ffmpegURL,
                arguments: arguments,
                standardInput: nil
            ) { chunk in
                if let fraction = parser.consume(chunk) { progress(fraction) }
            }
        } else {
            result = try await executor.run(executable: ffmpegURL, arguments: arguments, standardInput: nil)
        }
        guard result.status == 0 else { throw AppError.processFailed(tool: "FFmpeg", code: result.status, message: result.standardError) }
        guard fileManager.fileExists(atPath: temporaryOutput.path) else {
            throw AppError.processFailed(tool: "FFmpeg", code: -1, message: "封装进程结束但没有生成输出文件。")
        }
        if outputExists {
            _ = try fileManager.replaceItemAt(output, withItemAt: temporaryOutput)
        } else {
            try fileManager.moveItem(at: temporaryOutput, to: output)
        }
        progress(1)
    }

    public static func subtitleFormat(for codec: String) throws -> SubtitleFormat {
        switch codec.lowercased() {
        case "subrip", "srt": return .srt
        case "ass", "ssa": return .ass
        case "webvtt": return .webVTT
        default: throw AppError.unsupportedSubtitle("当前版本不支持字幕编码：\(codec)。")
        }
    }

    public static func fileExtension(for format: SubtitleFormat) -> String {
        switch format { case .srt: return "srt"; case .ass: return "ass"; case .webVTT: return "vtt" }
    }
}

private enum FileSafety {
    static func refersToSameFile(
        _ first: URL,
        _ second: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let firstResolved = first.resolvingSymlinksInPath().standardizedFileURL
        let secondResolved = second.resolvingSymlinksInPath().standardizedFileURL
        if firstResolved.path == secondResolved.path { return true }

        guard fileManager.fileExists(atPath: first.path),
              fileManager.fileExists(atPath: second.path),
              let firstAttributes = try? fileManager.attributesOfItem(atPath: firstResolved.path),
              let secondAttributes = try? fileManager.attributesOfItem(atPath: secondResolved.path),
              let firstDevice = firstAttributes[.systemNumber] as? NSNumber,
              let secondDevice = secondAttributes[.systemNumber] as? NSNumber,
              let firstNode = firstAttributes[.systemFileNumber] as? NSNumber,
              let secondNode = secondAttributes[.systemFileNumber] as? NSNumber else { return false }
        return firstDevice == secondDevice && firstNode == secondNode
    }
}

private final class FFmpegProgressParser: @unchecked Sendable {
    private let durationSeconds: Double
    private let lock = NSLock()
    private var pending = ""

    init(durationSeconds: Double) {
        self.durationSeconds = durationSeconds
    }

    func consume(_ chunk: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        let lines = pending.components(separatedBy: .newlines)
        pending = lines.last ?? ""
        var latest: Double?
        for line in lines.dropLast() {
            if line == "progress=end" {
                latest = 1
            } else if line.hasPrefix("out_time_us=") || line.hasPrefix("out_time_ms="),
                      let rawValue = Double(line.split(separator: "=", maxSplits: 1).last ?? "") {
                latest = min(0.99, max(0, (rawValue / 1_000_000) / durationSeconds))
            } else if line.hasPrefix("out_time="),
                      let value = line.split(separator: "=", maxSplits: 1).last,
                      let seconds = Self.clockSeconds(String(value)) {
                latest = min(0.99, max(0, seconds / durationSeconds))
            }
        }
        return latest
    }

    private static func clockSeconds(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }
}

private final class MKVExtractProgressParser: @unchecked Sendable {
    private static let percentExpression = try? NSRegularExpression(pattern: "([0-9]{1,3})%")
    private let lock = NSLock()
    private var pending = ""

    func consume(_ chunk: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        pending = String(pending.suffix(1_024))
        guard let expression = Self.percentExpression,
              let match = expression.matches(
                in: pending,
                range: NSRange(pending.startIndex..., in: pending)
              ).last,
              let range = Range(match.range(at: 1), in: pending),
              let percent = Double(pending[range]) else { return nil }
        return min(1, max(0, percent / 100))
    }
}

private final class BitmapDecoderProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func consume(_ chunk: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        pending += chunk
        let lines = pending.components(separatedBy: .newlines)
        pending = lines.last ?? ""
        var latest: Double?
        for line in lines.dropLast() where line.hasPrefix("progress=") {
            if let value = Double(line.dropFirst("progress=".count)) {
                latest = min(1, max(0, value))
            }
        }
        return latest
    }
}
