import XCTest
@testable import MKVSubtitleCore

final class PipelineSafetyAuditTests: XCTestCase {
    private let track = SubtitleTrack(streamIndex: 2, codec: "subrip", language: "eng", title: "", isDefault: false, isForced: false, isSDH: false, isText: true)
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testExistingOutputMissingFolderAndOriginalAliasesFailBeforeExtraction() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Film.mkv")
        try Data([1]).write(to: input)
        let existing = root.appendingPathComponent("Film.srt")
        try Data("keep this".utf8).write(to: existing)
        let alias = root.appendingPathComponent("alias.srt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input)
        let hardLink = root.appendingPathComponent("hardlink.srt")
        try FileManager.default.linkItem(at: input, to: hardLink)
        let executor = AuditExtraction()
        let pipeline = TranslationPipeline(ffmpeg: .init(ffmpegURL: URL(fileURLWithPath: "/unused"), executor: executor), provider: MockTranslationProvider())
        for (destination, overwrite) in [(existing, false), (alias, true), (hardLink, true), (input, true), (root.appendingPathComponent("missing/out.srt"), false)] {
            do {
                _ = try await pipeline.run(input: input, track: track, movie: .init(originalTitle: "Test"), output: destination, existingSubtitleCount: 1, overwrite: overwrite) { _ in }
                XCTFail("Unsafe destination must be rejected")
            } catch { /* Every destination is deliberately invalid. */ }
        }
        let calls = await executor.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep this")
        XCTAssertEqual(try Data(contentsOf: input), Data([1]))
    }

    func testVideoChangingDuringTranslationDoesNotPublishStaleSubtitle() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Film.mkv")
        try Data([1]).write(to: input)
        let output = root.appendingPathComponent("Film.srt")
        let pipeline = TranslationPipeline(
            ffmpeg: .init(ffmpegURL: URL(fileURLWithPath: "/unused"), executor: AuditExtraction()),
            provider: ChangingVideoProvider(input: input), jobStore: JobStore(rootURL: root.appendingPathComponent("Jobs"))
        )
        do {
            _ = try await pipeline.run(input: input, track: track, movie: .init(originalTitle: "Test"), output: output, existingSubtitleCount: 1, overwrite: false) { _ in }
            XCTFail("Changed media must be rejected")
        } catch let error as AppError { guard case .invalidMedia = error else { return XCTFail("Unexpected \(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledModelVerificationStopsBeforeReadingModel() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await WhisperModelStore.verify(URL(fileURLWithPath: "/nonexistent-model"), model: .small)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

private actor AuditExtraction: ProcessExecuting {
    var calls = 0
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        calls += 1
        let document = SubtitleDocument(format: .srt, cues: [.init(id: 1, startMilliseconds: 0, endMilliseconds: 1000, text: "Hello")])
        try SubtitleWriter().write(document, to: URL(fileURLWithPath: arguments.last!))
        return .init(status: 0, standardOutput: "", standardError: "")
    }
}

private struct ChangingVideoProvider: TranslationProvider {
    let input: URL
    func translate(_ request: TranslationRequest) async throws -> String {
        try Data([1, 2]).write(to: input)
        return #"{"items":[{"id":1,"text":"你好"}]}"#
    }
}
