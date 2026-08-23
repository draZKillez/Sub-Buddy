import Foundation
import XCTest
@testable import MKVSubtitleCore

final class TranslationPipelineOutputTests: XCTestCase {
    func testSidecarModeWritesBilingualSRTWithoutMuxing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let input = root.appendingPathComponent("Movie Name.mkv")
        let output = root.appendingPathComponent("Movie Name.srt")
        try Data().write(to: input)
        let executor = SubtitleExtractingExecutor()
        let pipeline = TranslationPipeline(
            ffmpeg: FFmpegService(ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"), executor: executor),
            provider: MockTranslationProvider(),
            chunker: TranslationChunker(configuration: .init(
                targetCoreCount: 500,
                maximumCoreCount: 500,
                maximumCoreCharacters: 80_000,
                contextCount: 50
            )),
            jobStore: JobStore(rootURL: root.appendingPathComponent("Jobs", isDirectory: true))
        )
        let track = SubtitleTrack(
            streamIndex: 2,
            codec: "subrip",
            language: "eng",
            title: "English",
            isDefault: false,
            isForced: false,
            isSDH: false,
            isText: true
        )

        let result = try await pipeline.run(
            input: input,
            track: track,
            movie: MovieInfo(originalTitle: "Movie Name"),
            output: output,
            existingSubtitleCount: 1,
            outputMode: .bilingual,
            deliveryMode: .sidecarSRT,
            overwrite: false
        ) { _ in }

        XCTAssertEqual(result, output)
        XCTAssertEqual(executor.invocationCount, 1, "Sidecar mode must extract once and never call FFmpeg muxing")
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("【模拟翻译】Hello there.\nHello there."))
        XCTAssertTrue(text.contains("00:00:01,000 --> 00:00:02,000"))
    }
}

private final class SubtitleExtractingExecutor: ProcessExecuting, @unchecked Sendable {
    private(set) var invocationCount = 0

    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        invocationCount += 1
        guard let outputPath = arguments.last else {
            return ProcessResult(status: 1, standardOutput: "", standardError: "Missing output")
        }
        let source = """
        1
        00:00:01,000 --> 00:00:02,000
        Hello there.

        """
        try Data(source.utf8).write(to: URL(fileURLWithPath: outputPath))
        return ProcessResult(status: 0, standardOutput: "", standardError: "")
    }
}
