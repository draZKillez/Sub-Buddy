import XCTest
@testable import MKVSubtitleCore

final class CodexFailureTests: XCTestCase {
    private func transcript(code: String, message: String) throws -> String {
        let nested = String(decoding: try JSONSerialization.data(withJSONObject: [
            "error": ["type": "invalid_request_error", "code": code, "message": message], "status": 400
        ]), as: UTF8.self)
        let event = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "error", "message": nested]), as: UTF8.self)
        return #"{"type":"thread.started","thread_id":"private-thread-id"}"# + "\n" + event
    }

    func testNestedSchemaFailureIsActionableAndNeverAutomaticallyRetried() async throws {
        let jsonl = try transcript(code: "invalid_json_schema", message: "Invalid schema: \\n is not allowed in string literals")
        for status: Int32 in [0, 1] {
            let executor = FailureExecutor(result: .init(status: status, standardOutput: jsonl, standardError: ""))
            let provider = CodexTranslationProvider(bridge: .init(codexURL: URL(fileURLWithPath: "/unused"), executor: executor))
            do {
                _ = try await TranslationEngine(provider: provider).translate(
                    chunk: .init(index: 0, core: [.init(id: 99, startMilliseconds: 0, endMilliseconds: 1000, text: "First\nSecond")], previousContext: [], nextContext: []),
                    movie: .init(originalTitle: "Test"), glossary: []
                )
                XCTFail("Schema rejection must stop")
            } catch let error as AppError {
                XCTAssertEqual(error, .codexInvalidRequest)
                XCTAssertFalse(error.localizedDescription.contains("thread_id"))
                XCTAssertFalse(error.localizedDescription.contains("properties"))
            }
            let count = await executor.calls
            XCTAssertEqual(count, 1)
        }
    }

    func testQuotaClassificationUsesFailureEventNotWarningsOrSubtitleText() async throws {
        let event = try transcript(code: "insufficient_quota", message: "Model access quota exceeded")
        let executor = FailureExecutor(result: .init(status: 1, standardOutput: event,
                                                    standardError: "WARNING: authentication configuration ignored; connection diagnostics"))
        do {
            _ = try await CodexBridge(codexURL: URL(fileURLWithPath: "/unused"), executor: executor).executeTranslation(prompt: "test")
            XCTFail("Expected quota error")
        } catch let error as AppError { XCTAssertEqual(error, .codexQuotaUnavailable) }
    }

    func testUnknownServiceFailureIsBoundedAndRedactsTokens() throws {
        let jsonl = try transcript(code: "unknown_error", message: "Bearer secretBearer access_token=secretAccess sk-secretKey " + String(repeating: "x", count: 3000))
        let details = CodexFailureDetails.parse(jsonl)
        XCTAssertLessThan(details.summary.count, 700)
        XCTAssertFalse(details.summary.contains("secretBearer"))
        XCTAssertFalse(details.summary.contains("secretAccess"))
        XCTAssertFalse(details.summary.contains("sk-secretKey"))
        XCTAssertFalse(details.summary.contains("private-thread-id"))
    }
}

private actor FailureExecutor: ProcessExecuting {
    let result: ProcessResult
    var calls = 0
    init(result: ProcessResult) { self.result = result }
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        calls += 1
        return result
    }
}
