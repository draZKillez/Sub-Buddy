import XCTest
@testable import MKVSubtitleCore

final class CodexModelCatalogTests: XCTestCase {
    private let model = #"{"model":"gpt-5.6-luna","displayName":"Luna 月亮","supportedReasoningEfforts":[{"reasoningEffort":"none"},{"reasoningEffort":"low"},{"reasoningEffort":"future"}],"hidden":false}"#

    func testDecodeCapabilitiesKeepsOnlyKnownEfforts() throws {
        let page = try CodexModelCatalog.decodePage(Data("{\"data\":[\(model)],\"nextCursor\":null}".utf8))
        XCTAssertEqual(page.data.first?.efforts, [.none, .low])
        XCTAssertEqual(page.data.first?.displayName, "Luna 月亮")
    }

    func testLunaRetainsVerifiedNoneOverrideWhenCatalogOmitsIt() throws {
        let json = #"{"data":[{"model":"gpt-5.6-luna","displayName":"Luna","supportedReasoningEfforts":[{"reasoningEffort":"low"}]},{"model":"future-model","displayName":"Future","supportedReasoningEfforts":[{"reasoningEffort":"high"}]}]}"#
        let page = try CodexModelCatalog.decodePage(Data(json.utf8))
        XCTAssertEqual(page.data[0].translationEfforts, [.none, .low])
        XCTAssertEqual(page.data[1].translationEfforts, [.high])
    }

    func testHandshakePaginationAndDeduplication() async throws {
        let script = """
        #!/bin/sh
        read -r init
        case "$init" in *initialize*) ;; *) exit 3;; esac
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r ready
        case "$ready" in *initialized*) ;; *) exit 4;; esac
        read -r request
        printf '%s\\n' '{"method":"notification"}' '{"id":2,"result":{"data":[\(model)],"nextCursor":"page2"}}'
        read -r request
        case "$request" in *page2*) ;; *) exit 5;; esac
        printf '%s\\n' '{"id":3,"result":{"data":[\(model)],"nextCursor":null}}'
        read -r end
        """
        let url = try fixture(script)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let models = try await CodexModelCatalog().refresh(executable: url)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].model, CodexModel.luna.rawValue)
    }

    func testRepeatedCursorStopsInsteadOfLooping() async throws {
        let script = """
        #!/bin/sh
        read -r init
        printf '%s\\n' '{"id":1,"result":{}}'
        read -r ready
        read -r request
        printf '%s\\n' '{"id":2,"result":{"data":[\(model)],"nextCursor":"same"}}'
        read -r request
        printf '%s\\n' '{"id":3,"result":{"data":[\(model)],"nextCursor":"same"}}'
        read -r end
        """
        let url = try fixture(script)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do { _ = try await CodexModelCatalog().refresh(executable: url); XCTFail("Expected repeated cursor error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Sub Buddy")) }
    }

    func testHungServerTimesOut() async throws {
        let url = try fixture("#!/bin/sh\nread -r init\nread -r never\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let start = Date()
        do { _ = try await CodexModelCatalog().refresh(executable: url, timeout: 0.2); XCTFail("Expected timeout") }
        catch { XCTAssertLessThan(Date().timeIntervalSince(start), 4) }
    }

    func testMissingCLIAndCancelledRefresh() async throws {
        do { _ = try await CodexModelCatalog().refresh(executable: nil); XCTFail("Expected missing CLI") }
        catch let error as AppError {
            guard case .toolMissing = error else { return XCTFail("\(error)") }
        }
        let url = try fixture("#!/bin/sh\nread -r init\nread -r never\n")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let task = Task { try await CodexModelCatalog().refresh(executable: url) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    }

    func testLiveModelListWhenExplicitlyEnabled() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUBBUDDY_TEST_MODEL_LIST_CLI"] else {
            throw XCTSkip("Opt-in local Codex discovery; no model generation.")
        }
        let models = try await CodexModelCatalog().refresh(executable: URL(fileURLWithPath: path))
        XCTAssertFalse(models.isEmpty)
        print("Model discovery: \(models.map { "\($0.model):\($0.efforts.map(\.rawValue).joined(separator: ","))" }.joined(separator: "; "))")
    }

    private func fixture(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SubBuddy-CatalogTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mock-codex")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
