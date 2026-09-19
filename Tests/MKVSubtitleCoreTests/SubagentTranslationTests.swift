import Foundation
import XCTest
@testable import MKVSubtitleCore

final class SubagentTranslationTests: XCTestCase {
    private func cues(_ count: Int) -> [SubtitleCue] {
        guard count > 0 else { return [] }
        return (1...count).map { .init(id: $0, startMilliseconds: Int64($0 * 1_000), endMilliseconds: Int64($0 * 1_000 + 800), text: "Hello friend \($0).") }
    }
    private func request(_ source: [SubtitleCue]) -> TranslationRequest {
        .init(chunk: .init(index: 0, core: source, previousContext: [], nextContext: []),
              movie: .init(originalTitle: "Original synthetic dialogue"), glossary: [.init(source: "Buddy", target: "仲間")],
              sourceLanguage: .english, targetLanguage: .japanese)
    }

    func testDynamicPartitionSmallLargeAndBalancedTail() throws {
        for (count, sizes) in [(100, [100]), (300, [300]), (301, [151,150]),
                               (500, [250,250]), (750, [188,188,187,187]),
                               (2000, Array(repeating: 250, count: 8))] {
            let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(cues(count)))
            XCTAssertEqual(tasks.map { $0.chunk.core.count }, sizes)
            XCTAssertEqual(tasks.flatMap { $0.chunk.core.map(\.id) }, Array(1...count))
            XCTAssertTrue(tasks.allSatisfy { $0.targetLanguage == .japanese && $0.glossary == tasks[0].glossary })
        }
        let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(cues(2000)))
        XCTAssertEqual(tasks[1].chunk.previousContext.map(\.id), Array(201...250))
        XCTAssertEqual(tasks[1].chunk.nextContext.map(\.id), Array(501...550))
        XCTAssertThrowsError(try CodexSubtitleTaskPlanner.tasks(for: request(cues(2401))))
        XCTAssertThrowsError(try CodexSubtitleTaskPlanner.tasks(for: request([])))
    }

    func testCharacterLimitAndNoEmptyChunks() throws {
        let source = (1...10).map { SubtitleCue(id: $0, startMilliseconds: 0, endMilliseconds: 1, text: String(repeating: "长", count: 12_000)) }
        let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(source))
        XCTAssertEqual(tasks.flatMap { $0.chunk.core.map(\.id) }, Array(1...10))
        XCTAssertTrue(tasks.allSatisfy { !$0.chunk.core.isEmpty && $0.chunk.core.reduce(0, { $0 + $1.text.count }) <= 30_000 })
    }

    func testLowestSupportedReasoningInBothModes() {
        XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: false, supported: [.low]), .low)
        XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: false, supported: [.high,.none,.low]), CodexReasoningEffort.none)
        XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: true, supported: [.none,.high,.low]), .low)
        XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: true, supported: [.minimal,.low]), .minimal)
        XCTAssertNil(CodexTranslationReasoningPolicy.effort(subagents: true, supported: [.none]))
        XCTAssertNil(CodexTranslationReasoningPolicy.effort(subagents: false, supported: []))
    }

    func testRefreshRetainsValidEffortAndReplacesUnsupportedSelection() {
        for subagents in [false, true] {
            XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: subagents, supported: [.low, .high], selected: .high), .high)
            XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: subagents, supported: [.low, .medium], selected: .high), .low)
            XCTAssertEqual(CodexTranslationReasoningPolicy.effort(subagents: subagents, supported: [.low, .medium], selected: CodexReasoningEffort.none), .low)
        }
        XCTAssertEqual(CodexTranslationReasoningPolicy.options(subagents: true, supported: [.high,.none,.low,.high]), [.low,.high])
    }

    func testCoordinatorPromptPreservesUserEffortInsteadOfForcingLow() throws {
        let provider = CodexSubagentTranslationProvider(bridge: .init(codexURL: nil, model: "gpt-5.5", reasoningEffort: .high))
        let prompt = provider.buildPrompt(try CodexSubtitleTaskPlanner.tasks(for: request(cues(301))))
        XCTAssertTrue(prompt.contains("same model gpt-5.5 and reasoning effort high"))
        XCTAssertTrue(prompt.contains("Do not override the model, effort or sandbox"))
    }

    func testRollingQueueOutOfOrderAndDuplicateResults() throws {
        let source = cues(601)
        let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(source))
        var collector = CodexSubagentCollector(parts: tasks.map { $0.chunk.core })
        var accepted: [Int] = []
        for line in try transcript(tasks).split(separator: "\n") {
            accepted += try collector.consume(Data(line.utf8)).flatMap { $0.items.map(\.id) }
        }
        try collector.finish()
        XCTAssertEqual(accepted.count, 601)
        XCTAssertEqual(Set(accepted), Set(1...601))
        XCTAssertEqual(collector.response.items.map(\.id), Array(1...601))
    }

    func testMoreThanTwoOpenChildrenAndReuseAreRejected() throws {
        let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(cues(601)))
        var collector = CodexSubagentCollector(parts: tasks.map { $0.chunk.core })
        _ = try collector.consume(event(["type":"thread.started", "thread_id":"root"]))
        _ = try collector.consume(spawn(0))
        _ = try collector.consume(spawn(1))
        XCTAssertThrowsError(try collector.consume(spawn(2)))
        XCTAssertThrowsError(try collector.finish())
    }

    func testFramerHandlesEveryUTF8ByteBoundaryAndEOF() throws {
        let text = "{\"type\":\"中文🌍\"}\n{\"type\":\"最後\"}"
        var framer = CodexJSONLFramer()
        var lines: [Data] = []
        for byte in text.utf8 { lines += try framer.append(Data([byte])) }
        if let tail = try framer.finish() { lines.append(tail) }
        XCTAssertEqual(lines.map { String(decoding:$0, as:UTF8.self) }.joined(separator:"\n"), text)
        var oversized = CodexJSONLFramer()
        XCTAssertThrowsError(try oversized.append(Data(repeating:65, count:4*1_024*1_024+1)))
    }

    func testRejectedSpawnDrainsExistingWorkAndLeavesMissingIDsForRepair() throws {
        let source = cues(4)
        var collector = CodexSubagentCollector(parts: [Array(source.prefix(2)), Array(source.suffix(2))])
        _ = try collector.consume(event(["type":"thread.started", "thread_id":"root"]))
        _ = try collector.consume(spawn(0))
        _ = try collector.consume(event(["type":"item.completed", "item":["id":"failed", "type":"collab_tool_call", "tool":"spawn_agent", "sender_thread_id":"root", "receiver_thread_ids":[], "agents_states":[:], "status":"failed"]]))
        let response = TranslationResponse(items: source.prefix(2).map { .init(id:$0.id, text:"译文", source:$0.text) }, glossaryUpdates:[])
        let raw = String(decoding:try JSONEncoder().encode(response), as:UTF8.self)
        let accepted = try collector.consume(event(["type":"item.completed", "item":["id":"wait", "type":"collab_tool_call", "tool":"wait", "sender_thread_id":"root", "receiver_thread_ids":["child0"], "status":"completed", "agents_states":["child0":["status":"completed", "message":raw]]]]))
        XCTAssertEqual(accepted.flatMap { $0.items.map(\.id) }, [1,2])
        _ = try collector.consume(event(["type":"turn.completed"]))
        try collector.finish()
        XCTAssertEqual(collector.response.items.map(\.id), [1,2])
    }

    func testRepeatedRejectedSpawnsHaveFiniteLimitAndNoMissingToolMessage() throws {
        var collector = CodexSubagentCollector(parts: [cues(1)])
        _ = try collector.consume(event(["type":"thread.started", "thread_id":"root"]))
        for index in 0..<3 {
            let data = try event(["type":"item.completed", "item":["id":"failed\(index)", "type":"collab_tool_call", "tool":"spawn_agent", "sender_thread_id":"root", "receiver_thread_ids":[], "status":"failed"]])
            if index < 2 { _ = try collector.consume(data) }
            else {
                XCTAssertThrowsError(try collector.consume(data)) { error in
                    guard case .processFailed = error as? AppError else { return XCTFail("Must not misreport a missing CLI") }
                }
            }
        }
    }

    func testProviderStreamsTasksUsesOneSessionAndCoordinatorDoesNotTranslate() async throws {
        let source = cues(601)
        let tasks = try CodexSubtitleTaskPlanner.tasks(for: request(source))
        let executor = AgentExecutor(output: try transcript(tasks))
        let provider = CodexSubagentTranslationProvider(bridge: .init(codexURL: URL(fileURLWithPath:"/test/codex"), reasoningEffort:.high, executor:executor))
        var accepted = 0
        let raw = try await provider.translate(request(source)) { partial in
            accepted += try TranslationValidator().validatePartial(rawJSON:partial, expectedIDs:Array(1...601)).items.count
        }
        XCTAssertEqual(accepted, 601)
        XCTAssertEqual(try TranslationValidator().validate(rawJSON:raw, expectedIDs:Array(1...601)).items.count, 601)
        let (calls,args,input) = await executor.snapshot()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(args.contains("agents.max_concurrent_threads_per_session=2"))
        XCTAssertTrue(args.contains("agents.default_subagent_reasoning_effort=\"high\""))
        XCTAssertTrue(args.contains("model_reasoning_effort=\"high\""))
        XCTAssertTrue(input.contains("ONLY the coordinator"))
        XCTAssertTrue(input.contains("Japanese"))
        XCTAssertEqual(provider.maximumConcurrentBatches, 1)
    }

    func testStorageFailureCancelsCLIAndNeverRetries() async throws {
        let source = cues(601)
        let executor = AgentExecutor(output: try transcript(CodexSubtitleTaskPlanner.tasks(for:request(source))), hang:true)
        let provider = CodexSubagentTranslationProvider(bridge:.init(codexURL:URL(fileURLWithPath:"/test/codex"), executor:executor))
        do {
            _ = try await provider.translate(request(source)) { _ in throw CocoaError(.fileWriteOutOfSpace) }
            XCTFail("Expected storage error")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let cancelled = await executor.cancelled
        XCTAssertTrue(cancelled)
    }

    func testQuotaEventClassifiedWithoutRetry() async throws {
        let executor = AgentExecutor(output:String(decoding:try event(["type":"turn.failed","error":["message":"rate_limit 429"]]),as:UTF8.self))
        let provider = CodexSubagentTranslationProvider(bridge:.init(codexURL:URL(fileURLWithPath:"/test/codex"),executor:executor))
        do { _ = try await provider.translate(request(cues(601))); XCTFail("Expected quota error") }
        catch let error as AppError { guard case .codexQuotaUnavailable = error else { return XCTFail("Wrong error: \(error)") } }
        let calls = await executor.snapshot().0
        XCTAssertEqual(calls, 1)
    }

    func testSpawnQuotaErrorIsNeverTreatedAsRecoverableCapacity() throws {
        var collector = CodexSubagentCollector(parts: [cues(1)])
        _ = try collector.consume(event(["type":"thread.started", "thread_id":"root"]))
        let data = try event(["type":"item.completed", "item":["id":"failed", "type":"collab_tool_call", "tool":"spawn_agent", "sender_thread_id":"root", "receiver_thread_ids":[], "status":"failed", "error":["message":"capacity unavailable: usage limit reached"]]])
        XCTAssertThrowsError(try collector.consume(data)) { error in
            guard case let .processFailed(_, _, message) = error as? AppError else { return XCTFail("Expected classified service failure") }
            XCTAssertTrue(message.contains("usage limit"))
        }
    }

    func testEngineKeepsStreamedPartsAndRepairsOnlyMissingIDs() async throws {
        let provider = StreamingRepairProvider()
        var saved: [Int] = []
        let result = try await TranslationEngine(provider:provider).translate(chunk:request(cues(3)).chunk,
            movie:.init(originalTitle:"Synthetic"), glossary:[], onValidated:{ saved += $0.items.map(\.id) })
        XCTAssertEqual(result.items.map(\.id), [1,2,3])
        let requests = await provider.requests
        XCTAssertEqual(requests, [[1,2,3],[2]])
        XCTAssertEqual(Array(saved.prefix(2)), [1,3])
    }

    func testThrownInvalidOutputAutomaticallyRetriesExactlyTwice() async throws {
        let provider = ThrowingFormatProvider()
        do {
            _ = try await TranslationEngine(provider:provider).translate(chunk:request(cues(3)).chunk,
                movie:.init(originalTitle:"Synthetic"), glossary:[])
            XCTFail("Must stop after initial request and two retries")
        } catch let error as AppError {
            guard case .invalidTranslation = error else { return XCTFail("Wrong error") }
        }
        let calls = await provider.calls
        XCTAssertEqual(calls, 3)
    }

    func testCheckpointFormatErrorIsNotMistakenForModelFailure() async throws {
        let provider = StreamingRepairProvider()
        do {
            _ = try await TranslationEngine(provider: provider).translate(
                chunk: request(cues(3)).chunk, movie: .init(originalTitle: "Synthetic"), glossary: [],
                onValidated: { _ in throw AppError.invalidTranslation("checkpoint failed") })
            XCTFail("Checkpoint errors must propagate")
        } catch let error as AppError {
            guard case .invalidTranslation(let detail) = error else { return XCTFail("Wrong error") }
            XCTAssertEqual(detail, "checkpoint failed")
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testOptInLiveOfficialSubagents() async throws {
        guard let path = ProcessInfo.processInfo.environment["SUBBUDDY_SUBAGENT_CODEX"] else {
            throw XCTSkip("Explicitly enable to run synthetic live Codex tasks.")
        }
        let count = ProcessInfo.processInfo.environment["SUBBUDDY_SUBAGENT_FULL"] == "1" ? 2000 : 601
        let provider = CodexSubagentTranslationProvider(bridge:.init(codexURL:URL(fileURLWithPath:path), reasoningEffort:.low, executor:AgentTraceExecutor()))
        let result = try await TranslationEngine(provider:provider).translate(chunk:request(cues(count)).chunk,
            movie:request(cues(count)).movie, glossary:[], sourceLanguage:.english, targetLanguage:.japanese)
        XCTAssertEqual(result.items.count, count)
    }

    private func event(_ object:[String:Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject:object, options:[.sortedKeys])
    }
    private func spawn(_ part:Int) throws -> Data {
        try event(["type":"item.completed", "item":["id":"spawn\(part)","type":"collab_tool_call","tool":"spawn_agent",
            "sender_thread_id":"root","receiver_thread_ids":["child\(part)"],"prompt":"SUBBUDDY_PART_\(part+1)",
            "status":"completed","agents_states":["child\(part)":["status":"running"]]]])
    }
    private func transcript(_ tasks:[TranslationRequest]) throws -> String {
        var events = [try event(["type":"thread.started","thread_id":"root"]), try spawn(0), try spawn(1)]
        func done(_ part:Int, suffix:String = "") throws -> Data {
            let raw = String(decoding:try JSONEncoder().encode(TranslationResponse(items:tasks[part].chunk.core.map {
                .init(id:$0.id, text:"訳 \($0.id)", source:$0.text)
            })),as:UTF8.self)
            return try event(["type":"item.completed","item":["id":"wait\(part)\(suffix)","type":"collab_tool_call","tool":"wait",
                "sender_thread_id":"root","agents_states":["child\(part)":["status":"completed","message":raw]]]])
        }
        // Task 2 finishes first; task 3 starts before task 1 completes.
        let order = [1,0] + Array(2..<tasks.count)
        var next = 2
        for part in order {
            events.append(try done(part))
            events.append(try done(part,suffix:"duplicate"))
            events.append(try event(["type":"item.completed","item":["id":"close\(part)","type":"collab_tool_call","tool":"close_agent",
                "sender_thread_id":"root","receiver_thread_ids":["child\(part)"],"status":"completed",
                "agents_states":["child\(part)":["status":"shutdown"]]]]))
            if next < tasks.count { events.append(try spawn(next)); next += 1 }
        }
        // Coordinator output, even if it contains subtitle-like text, is ignored.
        events.append(try event(["type":"item.completed","item":["id":"root-final","type":"agent_message","text":"{\"completed\":true}"]]))
        events.append(try event(["type":"turn.completed"]))
        return events.map { String(decoding:$0,as:UTF8.self) }.joined(separator:"\n")
    }
}

private actor ThrowingFormatProvider: TranslationProvider {
    var calls = 0
    func translate(_ request:TranslationRequest) async throws -> String {
        calls += 1
        throw AppError.invalidTranslation("Malformed model response")
    }
}

/// Synthetic live tests only. No auth files, movie files or credentials read.
private final class AgentTraceExecutor: DataStreamingProcessExecuting, @unchecked Sendable {
    let lock = NSLock()
    var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data) }
    func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        try await ProcessExecutor().run(executable: executable, arguments: arguments, standardInput: standardInput)
    }
    func run(executable: URL, arguments: [String], standardInput: Data?, standardOutputDataHandler: @escaping @Sendable (Data) -> Void) async throws -> ProcessResult {
        defer {
            if let path = ProcessInfo.processInfo.environment["SUBBUDDY_SUBAGENT_TRACE"] {
                try? snapshot().write(to: URL(fileURLWithPath: path), options: .atomic)
            }
        }
        return try await ProcessExecutor().run(executable: executable, arguments: arguments, standardInput: standardInput) { [self] (data: Data) in
            append(data)
            standardOutputDataHandler(data)
        }
    }
}

private actor StreamingRepairProvider: StreamingTranslationProvider {
    var requests: [[Int]] = []
    nonisolated var requiresSourceEcho: Bool { true }
    func translate(_ request: TranslationRequest) async throws -> String { try await translate(request, onPartial: { _ in }) }
    func translate(_ request: TranslationRequest, onPartial: (String) async throws -> Void) async throws -> String {
        requests.append(request.chunk.core.map(\.id))
        let remaining = request.chunk.core.filter { requests.count > 1 || $0.id != 2 }
        let raw = String(decoding: try JSONEncoder().encode(TranslationResponse(items: remaining.map {
            .init(id: $0.id, text: "译文 \($0.id)", source: $0.text)
        })), as: UTF8.self)
        try await onPartial(raw)
        return raw
    }
}

private actor AgentExecutor: DataStreamingProcessExecuting {
    let output: String
    let hang: Bool
    var calls = 0
    var arguments: [String] = []
    var input = ""
    var cancelled = false
    init(output: String, hang: Bool = false) { self.output = output; self.hang = hang }
    func snapshot() -> (Int, [String], String) { (calls, arguments, input) }
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        try await run(executable: executable, arguments: arguments, standardInput: standardInput, standardOutputDataHandler: { _ in })
    }
    func run(executable: URL, arguments: [String], standardInput: Data?, standardOutputDataHandler: @escaping @Sendable (Data) -> Void) async throws -> ProcessResult {
        calls += 1
        self.arguments = arguments
        input = String(decoding: standardInput ?? Data(), as: UTF8.self)
        standardOutputDataHandler(Data((output + "\n").utf8))
        do {
            if hang { try await Task.sleep(nanoseconds: 20_000_000_000) }
            try Task.checkCancellation()
        } catch { cancelled = true; throw error }
        return .init(status: 0, standardOutput: output, standardError: "")
    }
}
