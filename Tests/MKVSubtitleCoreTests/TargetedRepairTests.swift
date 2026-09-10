import XCTest
@testable import MKVSubtitleCore

final class TargetedRepairTests: XCTestCase {
    func testFinalSummaryDoesNotOverwriteOrResaveAcceptedStreamingItems() async throws {
        let cues = [1, 2].map { SubtitleCue(id: $0, startMilliseconds: 0, endMilliseconds: 1000, text: "Hello \($0)") }
        var saved: [[Int]] = []
        let result = try await TranslationEngine(provider: RepeatedStreamingProvider()).translate(
            chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
            movie: .init(originalTitle: "Test"), glossary: [],
            onValidated: { saved.append($0.items.map(\.id)) }
        )
        XCTAssertEqual(saved, [[1], [2]])
        XCTAssertEqual(result.items.first?.text, "已保存")
    }

    func testInvalidSavedFormattingIsRepairedInsteadOfBypassingValidation() async throws {
        let cue = SubtitleCue(id: 99, startMilliseconds: 0, endMilliseconds: 1000, text: "First\nSecond")
        let provider = LineRepairProvider()
        let result = try await TranslationEngine(provider: provider).translate(
            chunk: .init(index: 0, core: [cue], previousContext: [], nextContext: []),
            movie: .init(originalTitle: "Test"), glossary: [], completedItems: [99: "错误的一行"]
        )
        XCTAssertEqual(result.items.first?.text, "第一行\n第二行")
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testSingleCueRepairSchemaNeverEmbedsMultilineSourceAsEnum() throws {
        let cue = SubtitleCue(id: 99, startMilliseconds: 0, endMilliseconds: 1000, text: "First\nSecond...")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: TranslationOutputSchema.data(for: [cue])) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let array = try XCTUnwrap(properties["items"] as? [String: Any])
        let item = try XCTUnwrap(array["items"] as? [String: Any])
        let fields = try XCTUnwrap(item["properties"] as? [String: Any])
        let source = try XCTUnwrap(fields["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "string")
        XCTAssertNil(source["enum"])
        XCTAssertNil(source["const"])
        let wrong = #"{"items":[{"id":99,"source":"wrong source","text":"第一\n第二"}],"glossary_updates":[]}"#
        let assessment = try TranslationValidator().assessAlignment(rawJSON: wrong, expectedCues: [cue], requiresSourceEcho: true)
        XCTAssertEqual(assessment.issues[99], .sourceMismatch, "Removing an unsupported enum must not weaken local alignment")
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
        // Exercise an isolated repair as well as the original two-item batch;
        // 0.9.3's incompatible source enum only existed for one-item requests.
        for selected in [cues, Array(cues.prefix(1))] {
            let response = try await TranslationEngine(provider: provider).translate(
                chunk: .init(index: 0, core: selected,
                             previousContext: document.cues.filter { (89...98).contains($0.id) },
                             nextContext: document.cues.filter { (107...116).contains($0.id) }),
                movie: .init(originalTitle: "Hoppers"), glossary: []
            )
            XCTAssertEqual(response.items.map(\.id), selected.map(\.id))
            for item in response.items {
                let cue = try XCTUnwrap(cues.first { $0.id == item.id })
                XCTAssertEqual(item.source, cue.text)
                XCTAssertTrue(TranslationValidator.preservesFormatting(item.text, source: cue.text))
            }
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

private struct RepeatedStreamingProvider: StreamingTranslationProvider {
    var requiresSourceEcho: Bool { true }
    func translate(_ request: TranslationRequest) async throws -> String {
        try await translate(request, onPartial: { _ in })
    }
    func translate(_ request: TranslationRequest, onPartial: (String) async throws -> Void) async throws -> String {
        try await onPartial(#"{"items":[{"id":1,"source":"Hello 1","text":"已保存"}]}"#)
        return #"{"items":[{"id":1,"source":"Hello 1","text":"最终汇总改写"},{"id":2,"source":"Hello 2","text":"第二条"}]}"#
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
