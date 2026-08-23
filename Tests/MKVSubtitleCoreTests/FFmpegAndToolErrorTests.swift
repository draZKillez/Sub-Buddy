import XCTest
@testable import MKVSubtitleCore

final class FFmpegAndToolErrorTests: XCTestCase {
    func testToolLocatorPrefersBundledFFmpegTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BundledTools-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        for name in ["ffmpeg", "ffprobe"] {
            let url = tools.appendingPathComponent(name)
            try Data("tool".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let paths = ToolLocator(bundleResourceURL: root).locate()
        XCTAssertEqual(paths.ffmpeg, tools.appendingPathComponent("ffmpeg"))
        XCTAssertEqual(paths.ffprobe, tools.appendingPathComponent("ffprobe"))
    }

    func testExtractionArgumentsAreSeparateAndPreserveSpecialPaths() {
        let input = URL(fileURLWithPath: "/tmp/电影 [Final] $name.mkv")
        let output = URL(fileURLWithPath: "/tmp/字幕 文件.ass")
        let args = FFmpegArguments().extraction(input: input, streamIndex: 7, output: output)
        XCTAssertEqual(args, [
            "-y", "-v", "error", "-nostdin", "-nostats", "-progress", "pipe:1",
            "-i", input.path, "-map", "0:7", "-c:s", "copy", output.path
        ])
    }

    func testSpeechRecognitionAudioArgumentsAreSafeAndDoNotEncodeVideo() {
        let input = URL(fileURLWithPath: "/tmp/电影 $Final [1].mkv")
        let output = URL(fileURLWithPath: "/tmp/English audio.f32")
        let args = FFmpegArguments().speechAudioExtraction(input: input, streamIndex: 3, output: output)
        XCTAssertEqual(args, [
            "-y", "-v", "error", "-nostdin", "-nostats", "-progress", "pipe:1",
            "-i", input.path, "-map", "0:3", "-vn", "-sn", "-dn",
            "-ac", "1", "-ar", "16000", "-c:a", "pcm_f32le", "-f", "f32le", output.path
        ])
    }

    func testMKVExtractArgumentsUseTrackIDAndSeparatePaths() {
        let input = URL(fileURLWithPath: "/tmp/电影 file.mkv")
        let output = URL(fileURLWithPath: "/tmp/中文 subtitle.srt")
        XCTAssertEqual(
            MKVExtractArguments().extraction(input: input, trackID: 8, output: output),
            ["tracks", input.path, "8:\(output.path)"]
        )
    }

    func testMuxArgumentsKeepAllOriginalTracksAndAddChineseMetadata() throws {
        let input = URL(fileURLWithPath: "/tmp/movie.mkv")
        let subtitle = URL(fileURLWithPath: "/tmp/zh.srt")
        let output = URL(fileURLWithPath: "/tmp/movie_zh.mkv")
        let args = try FFmpegArguments().muxing(input: input, chineseSubtitle: subtitle, output: output, existingSubtitleCount: 3, overwrite: false)
        XCTAssertEqual(args, [
            "-n", "-v", "error", "-nostdin", "-nostats", "-progress", "pipe:1",
            "-i", input.path, "-i", subtitle.path,
            "-map", "0", "-map", "1:0", "-c", "copy",
            "-metadata:s:s:3", "language=zho", "-metadata:s:s:3", "title=简体中文",
            "-disposition:s:3", "0", output.path
        ])
    }

    func testMuxArgumentsCanNameBilingualTrack() throws {
        let input = URL(fileURLWithPath: "/tmp/movie.mkv")
        let subtitle = URL(fileURLWithPath: "/tmp/zh-Hans-bilingual.srt")
        let output = URL(fileURLWithPath: "/tmp/movie_zh_bilingual.mkv")
        let args = try FFmpegArguments().muxing(
            input: input,
            chineseSubtitle: subtitle,
            output: output,
            existingSubtitleCount: 2,
            trackTitle: "中英双语",
            languageCode: "zho",
            overwrite: false
        )
        XCTAssertTrue(args.contains("title=中英双语"))
        XCTAssertTrue(args.contains("language=zho"))
        XCTAssertEqual(args.suffix(1), [output.path])
    }

    func testMuxRefusesToOverwriteOriginal() {
        let input = URL(fileURLWithPath: "/tmp/movie.mkv")
        XCTAssertThrowsError(try FFmpegArguments().muxing(input: input, chineseSubtitle: URL(fileURLWithPath: "/tmp/zh.srt"), output: input, existingSubtitleCount: 0, overwrite: true)) { error in
            XCTAssertEqual(error as? AppError, .originalOverwriteForbidden)
        }
    }

    func testMuxRefusesSymlinkAndHardLinkAliasesOfOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuxAliasSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("movie.mkv")
        let symlink = root.appendingPathComponent("movie-symlink.mkv")
        let hardLink = root.appendingPathComponent("movie-hardlink.mkv")
        let subtitle = root.appendingPathComponent("subtitle.srt")
        try Data("original".utf8).write(to: input)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        try FileManager.default.linkItem(at: input, to: hardLink)

        for alias in [symlink, hardLink] {
            XCTAssertThrowsError(try FFmpegArguments().muxing(
                input: input,
                chineseSubtitle: subtitle,
                output: alias,
                existingSubtitleCount: 0,
                overwrite: true
            )) { error in
                XCTAssertEqual(error as? AppError, .originalOverwriteForbidden)
            }
        }
    }

    func testMissingFFmpegAndFFprobeReturnActionableErrors() async {
        let input = URL(fileURLWithPath: "/tmp/movie.mkv")
        let track = SubtitleTrack(streamIndex: 2, codec: "subrip", language: "eng", title: "English", isDefault: true, isForced: false, isSDH: false, isText: true)
        do {
            try await FFmpegService(ffmpegURL: nil).extractSubtitle(input: input, track: track, output: URL(fileURLWithPath: "/tmp/out.srt"))
            XCTFail("Expected missing FFmpeg")
        } catch let error as AppError {
            guard case let .toolMissing(name, guidance) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(name, "FFmpeg")
            XCTAssertTrue(guidance.contains("brew install ffmpeg"))
        } catch { XCTFail("Unexpected error: \(error)") }

        do {
            _ = try await MKVInspector(ffprobeURL: nil).inspect(input)
            XCTFail("Expected missing ffprobe")
        } catch let error as AppError {
            guard case let .toolMissing(name, guidance) = error else { return XCTFail("Unexpected error") }
            XCTAssertEqual(name, "ffprobe")
            XCTAssertTrue(guidance.contains("brew install ffmpeg"))
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testImageSubtitleHasRequiredOCRMessage() async {
        let input = URL(fileURLWithPath: "/tmp/movie.mkv")
        let track = SubtitleTrack(streamIndex: 4, codec: "hdmv_pgs_subtitle", language: "eng", title: "PGS", isDefault: false, isForced: false, isSDH: false, isText: false)
        do {
            try await FFmpegService(ffmpegURL: nil).extractSubtitle(input: input, track: track, output: URL(fileURLWithPath: "/tmp/out.sup"))
            XCTFail("Expected unsupported image subtitle")
        } catch {
            XCTAssertEqual(error.localizedDescription, "检测到图片字幕，当前版本暂不支持 OCR。")
        }
    }

    func testExtractionReportsFFmpegContainerScanProgress() async throws {
        let executor = StreamingFFmpegExecutor()
        let service = FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"), executor: executor)
        let track = SubtitleTrack(streamIndex: 8, codec: "subrip", language: "eng", title: "English", isDefault: false, isForced: false, isSDH: false, isText: true)
        let collector = FractionCollector()
        try await service.extractSubtitle(
            input: URL(fileURLWithPath: "/tmp/movie.mkv"),
            track: track,
            output: URL(fileURLWithPath: "/tmp/out.srt"),
            durationSeconds: 100
        ) { collector.append($0) }
        XCTAssertTrue(collector.values.contains { abs($0 - 0.5) < 0.001 })
        XCTAssertEqual(collector.values.last, 1)
    }

    func testExtractionPrefersMKVExtractFastPath() async throws {
        let executor = FastPathExecutor()
        let mkvextract = URL(fileURLWithPath: "/opt/homebrew/bin/mkvextract")
        let service = FFmpegService(
            ffmpegURL: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            mkvextractURL: mkvextract,
            executor: executor
        )
        let track = SubtitleTrack(streamIndex: 8, codec: "subrip", language: "eng", title: "English", isDefault: false, isForced: false, isSDH: false, isText: true)
        let output = URL(fileURLWithPath: "/tmp/out subtitle.srt")
        let collector = FractionCollector()
        try await service.extractSubtitle(
            input: URL(fileURLWithPath: "/tmp/movie.mkv"),
            track: track,
            output: output,
            durationSeconds: 100
        ) { collector.append($0) }
        XCTAssertEqual(executor.lastExecutable, mkvextract)
        XCTAssertEqual(executor.lastArguments, ["tracks", "/tmp/movie.mkv", "8:\(output.path)"])
        XCTAssertTrue(collector.values.contains(0.42))
        XCTAssertEqual(collector.values.last, 1)
    }

    func testMuxReportsRealContainerProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuxProgress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executor = StreamingFFmpegExecutor(createsOutput: true)
        let service = FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"), executor: executor)
        let collector = FractionCollector()
        let output = root.appendingPathComponent("movie-progress-test.mkv")
        try await service.mux(
            input: root.appendingPathComponent("movie.mkv"),
            chineseSubtitle: root.appendingPathComponent("movie.srt"),
            output: output,
            existingSubtitleCount: 2,
            overwrite: false,
            durationSeconds: 100
        ) { collector.append($0) }
        XCTAssertTrue(collector.values.contains { abs($0 - 0.5) < 0.001 })
        XCTAssertEqual(collector.values.last, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertNotEqual(executor.lastArguments.last, output.path, "FFmpeg must write a temporary file before publishing the output")
    }

    func testMuxFailurePreservesExistingOutputAndRemovesPartialFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuxFailureSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("movie.mkv")
        let subtitle = root.appendingPathComponent("movie.srt")
        let output = root.appendingPathComponent("movie_zh.mkv")
        try Data("input".utf8).write(to: input)
        try Data("subtitle".utf8).write(to: subtitle)
        try Data("old-output".utf8).write(to: output)
        let executor = MuxFileExecutor(status: 1, payload: Data("partial".utf8))
        let service = FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"), executor: executor)

        do {
            try await service.mux(
                input: input,
                chineseSubtitle: subtitle,
                output: output,
                existingSubtitleCount: 1,
                overwrite: true
            )
            XCTFail("Expected FFmpeg failure")
        } catch let error as AppError {
            guard case .processFailed = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(try Data(contentsOf: output), Data("old-output".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".partial.") }
        XCTAssertTrue(leftovers.isEmpty, "Partial mux files must be cleaned up: \(leftovers)")
    }

    func testSuccessfulMuxAtomicallyReplacesExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MuxReplaceSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("movie.mkv")
        let subtitle = root.appendingPathComponent("movie.srt")
        let output = root.appendingPathComponent("movie_zh.mkv")
        try Data("input".utf8).write(to: input)
        try Data("subtitle".utf8).write(to: subtitle)
        try Data("old-output".utf8).write(to: output)
        let executor = MuxFileExecutor(status: 0, payload: Data("new-output".utf8))
        let service = FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"), executor: executor)

        try await service.mux(
            input: input,
            chineseSubtitle: subtitle,
            output: output,
            existingSubtitleCount: 1,
            overwrite: true
        )

        XCTAssertEqual(try Data(contentsOf: output), Data("new-output".utf8))
        XCTAssertNotEqual(executor.lastArguments.last, output.path)
    }
}

private final class StreamingFFmpegExecutor: StreamingProcessExecuting, @unchecked Sendable {
    private let createsOutput: Bool
    private(set) var lastArguments: [String] = []

    init(createsOutput: Bool = false) {
        self.createsOutput = createsOutput
    }

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        lastArguments = arguments
        if createsOutput, let output = arguments.last {
            try Data("muxed".utf8).write(to: URL(fileURLWithPath: output))
        }
        return ProcessResult(status: 0, standardOutput: "", standardError: "")
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        standardOutputHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        lastArguments = arguments
        standardOutputHandler("out_time_us=50000000\nprogress=continue\n")
        standardOutputHandler("out_time_us=100000000\nprogress=end\n")
        if createsOutput, let output = arguments.last {
            try Data("muxed".utf8).write(to: URL(fileURLWithPath: output))
        }
        return ProcessResult(status: 0, standardOutput: "", standardError: "")
    }
}

private final class MuxFileExecutor: ProcessExecuting, @unchecked Sendable {
    let status: Int32
    let payload: Data?
    private(set) var lastArguments: [String] = []

    init(status: Int32, payload: Data?) {
        self.status = status
        self.payload = payload
    }

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        lastArguments = arguments
        if let payload, let output = arguments.last {
            try payload.write(to: URL(fileURLWithPath: output))
        }
        return ProcessResult(status: status, standardOutput: "", standardError: status == 0 ? "" : "simulated failure")
    }
}

private final class FractionCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
    func append(_ value: Double) {
        lock.lock(); storage.append(value); lock.unlock()
    }
}

private final class FastPathExecutor: StreamingProcessExecuting, @unchecked Sendable {
    var lastExecutable: URL?
    var lastArguments: [String] = []

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        lastExecutable = executable
        lastArguments = arguments
        return ProcessResult(status: 0, standardOutput: "", standardError: "")
    }

    func run(
        executable: URL,
        arguments: [String],
        standardInput: Data?,
        standardOutputHandler: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        lastExecutable = executable
        lastArguments = arguments
        standardOutputHandler("Progress: 42%\r")
        standardOutputHandler("Progress: 100%\r")
        return ProcessResult(status: 0, standardOutput: "", standardError: "")
    }
}
