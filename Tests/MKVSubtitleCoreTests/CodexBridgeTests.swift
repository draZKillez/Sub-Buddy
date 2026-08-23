import XCTest
@testable import MKVSubtitleCore

final class CodexBridgeTests: XCTestCase {
    func testParsesFinalAgentMessageFromJSONL() throws {
        let jsonl = """
        {"type":"thread.started","thread_id":"abc"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"1","type":"agent_message","text":"{\\"items\\":[{\\"id\\":1,\\"text\\":\\"你好\\"}]}"}}
        {"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}
        """
        let message = try CodexJSONLParser().finalAgentMessage(from: jsonl)
        XCTAssertEqual(message, #"{"items":[{"id":1,"text":"你好"}]}"#)
    }

    func testMissingCLIHasClearStatusAndError() async {
        let bridge = CodexBridge(codexURL: nil)
        let status = await bridge.connectionStatus()
        XCTAssertEqual(status, .cliMissing)
        do {
            _ = try await bridge.executeTranslation(prompt: "test")
            XCTFail("Expected missing tool error")
        } catch let error as AppError {
            guard case let .toolMissing(name, _) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(name, "Codex CLI")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCodexUsesExactModelJSONLEphemeralReadOnlyAndStdin() async throws {
        let executor = RecordingExecutor(result: ProcessResult(
            status: 0,
            standardOutput: #"{"type":"item.completed","item":{"type":"agent_message","text":"{}"}}"#,
            standardError: ""
        ))
        let url = URL(fileURLWithPath: "/tmp/codex")
        let bridge = CodexBridge(codexURL: url, model: CodexModel.terra.rawValue, executor: executor)
        let result = try await bridge.executeTranslation(prompt: "字幕上下文")
        XCTAssertEqual(result, "{}")
        XCTAssertEqual(executor.lastExecutable, url)
        XCTAssertEqual(Array(executor.lastArguments.prefix(6)), ["exec", "--ephemeral", "--json", "--sandbox", "read-only", "--skip-git-repo-check"])
        XCTAssertTrue(executor.lastArguments.contains("--ignore-user-config"))
        XCTAssertTrue(executor.lastArguments.contains("--ignore-rules"))
        XCTAssertTrue(executor.lastArguments.contains("model_reasoning_effort=\"none\""))
        XCTAssertTrue(executor.lastArguments.contains(where: { $0.contains("MKVSubtitleTranslator-Codex-") }))
        XCTAssertEqual(Array(executor.lastArguments.suffix(3)), ["-m", "gpt-5.6-terra", "-"])
        XCTAssertEqual(executor.lastInput, Data("字幕上下文".utf8))
    }

    func testChineseTitleCandidateProviderParsesAndDeduplicates() async throws {
        let executor = RecordingExecutor(result: ProcessResult(
            status: 0,
            standardOutput: #"{"type":"item.completed","item":{"type":"agent_message","text":"{\"candidates\":[\"降临\",\"降临\",\"异星入境\"]}"}}"#,
            standardError: ""
        ))
        let bridge = CodexBridge(codexURL: URL(fileURLWithPath: "/tmp/codex"), executor: executor)
        let candidates = try await CodexMovieMetadataProvider(bridge: bridge)
            .chineseTitleCandidates(originalTitle: "Arrival", year: 2016)
        XCTAssertEqual(candidates, ["降临", "异星入境"])
    }

    func testFiveHundredCoreCuesUseOneCodexProcessAndOneStdinPayload() async throws {
        let executor = RecordingExecutor(result: ProcessResult(
            status: 0,
            standardOutput: #"{"type":"item.completed","item":{"type":"agent_message","text":"{}"}}"#,
            standardError: ""
        ))
        let bridge = CodexBridge(codexURL: URL(fileURLWithPath: "/tmp/codex"), executor: executor)
        let cues = (1...500).map {
            SubtitleCue(id: $0, startMilliseconds: Int64($0 * 1_000), endMilliseconds: Int64($0 * 1_000 + 800), text: "Line \($0)")
        }
        let request = TranslationRequest(
            chunk: TranslationChunk(index: 0, core: cues, previousContext: [], nextContext: []),
            movie: MovieInfo(originalTitle: "Demo"),
            glossary: []
        )

        _ = try await CodexTranslationProvider(bridge: bridge).translate(request)

        XCTAssertEqual(executor.invocationCount, 1)
        let prompt = String(decoding: try XCTUnwrap(executor.lastInput), as: UTF8.self)
        XCTAssertTrue(prompt.contains("[1] Line 1"))
        XCTAssertTrue(prompt.contains("[500] Line 500"))
    }
}

private final class RecordingExecutor: ProcessExecuting, @unchecked Sendable {
    let result: ProcessResult
    var invocationCount = 0
    var lastExecutable: URL?
    var lastArguments: [String] = []
    var lastInput: Data?
    init(result: ProcessResult) { self.result = result }
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        invocationCount += 1
        lastExecutable = executable
        lastArguments = arguments
        lastInput = standardInput
        return result
    }
}
