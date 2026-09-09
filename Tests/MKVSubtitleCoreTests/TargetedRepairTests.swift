import XCTest
@testable import MKVSubtitleCore

final class TargetedRepairTests: XCTestCase {
    func testSingleCueRepairSchemaPinsExactOriginalSource() throws {
        let cue = SubtitleCue(id: 99, startMilliseconds: 0, endMilliseconds: 1000, text: "First\nSecond...")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: TranslationOutputSchema.data(for: [cue])) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let array = try XCTUnwrap(properties["items"] as? [String: Any])
        let item = try XCTUnwrap(array["items"] as? [String: Any])
        let fields = try XCTUnwrap(item["properties"] as? [String: Any])
        let source = try XCTUnwrap(fields["source"] as? [String: Any])
        XCTAssertEqual(source["enum"] as? [String], [cue.text])
    }

    /// Explicit local opt-in; CI never consumes an account or reads user media.
    func testOptInRealSubtitleTail() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["SUB_BUDDY_REPAIR_SOURCE"], let executable = env["SUB_BUDDY_REPAIR_CODEX"] else {
            throw XCTSkip("Set explicit local subtitle source and official Codex executable for live verification")
        }
        let document = try SubtitleParser().parse(contentsOf: URL(fileURLWithPath: source), format: .srt)
        let cues = document.cues.filter { [99, 106].contains($0.id) }
        XCTAssertEqual(cues.count, 2)
        let provider = CodexSubagentTranslationProvider(bridge: CodexBridge(codexURL: URL(fileURLWithPath: executable)))
        let response = try await TranslationEngine(provider: provider).translate(
            chunk: .init(index: 0, core: cues,
                         previousContext: document.cues.filter { (89...98).contains($0.id) },
                         nextContext: document.cues.filter { (107...116).contains($0.id) }),
            movie: .init(originalTitle: "Hoppers"), glossary: []
        )
        XCTAssertEqual(response.items.map(\.id), [99, 106])
        for item in response.items {
            let cue = try XCTUnwrap(cues.first { $0.id == item.id })
            XCTAssertEqual(item.source, cue.text)
            XCTAssertTrue(TranslationValidator.preservesFormatting(item.text, source: cue.text))
        }
    }

    func testDiagnosticDistinguishesAllRejectedItemReasons() throws {
        let cues = (1...7).map { SubtitleCue(id: $0, startMilliseconds: 0, endMilliseconds: 1000, text: "<i>First\nSecond</i>") }
        let items: [TranslationItem] = [
            .init(id: 2, text: "x", source: cues[1].text), .init(id: 2, text: "x", source: cues[1].text),
            .init(id: 3, text: "", source: cues[2].text),
            .init(id: 4, text: "x", source: "wrong source"),
            .init(id: 5, text: "第一\n第二", source: cues[4].text),
            .init(id: 6, text: "<i>第一第二</i>", source: cues[5].text),
            .init(id: 7, text: "<i>第一\n第二</i>", source: cues[6].text)
        ]
        let raw = String(decoding: try JSONEncoder().encode(TranslationResponse(items: items)), as: UTF8.self)
        let result = try TranslationValidator().assessAlignment(rawJSON: raw, expectedCues: cues, requiresSourceEcho: true)
        XCTAssertEqual(result.issues, [1: .missing, 2: .duplicate, 3: .empty, 4: .sourceMismatch, 5: .tagsMismatch, 6: .lineBreakMismatch])
        XCTAssertEqual(result.response.items.map(\.id), [7])
    }

    func testStubbornTwoLineCuesReceiveSpecificGuidanceAndIsolatedFinalRepair() async throws {
        let cues = [99, 106].map { SubtitleCue(id: $0, startMilliseconds: Int64($0 * 1000), endMilliseconds: Int64($0 * 1000 + 900), text: "First\nSecond") }
        let provider = LineRepairProvider()
        let result = try await TranslationEngine(provider: provider).translate(
            chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
            movie: .init(originalTitle: "Test"), glossary: [], targetLanguage: .japanese
        )
        let requests = await provider.requests
        XCTAssertEqual(requests.map { $0.chunk.core.map(\.id) }, [[99, 106], [99, 106], [99], [106]])
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.previousInvalidOutput?.contains("Do not merge lines") == true })
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.previousInvalidOutput?.contains("2 nonempty line(s)") == true })
        XCTAssertTrue(requests.allSatisfy { $0.targetLanguage == .japanese })
        XCTAssertEqual(result.items.map(\.id), [99, 106])
    }
}

private actor LineRepairProvider: TranslationProvider {
    nonisolated let requiresSourceEcho = true
    var requests: [TranslationRequest] = []
    func translate(_ request: TranslationRequest) async throws -> String {
        requests.append(request)
        let items = request.chunk.core.map { cue in
            TranslationItem(id: cue.id, text: request.chunk.core.count == 1 ? "第一行\n第二行" : "合并成一行", source: cue.text)
        }
        return String(decoding: try JSONEncoder().encode(TranslationResponse(items: items)), as: UTF8.self)
    }
}
