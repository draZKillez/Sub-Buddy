import CryptoKit
import Foundation
import XCTest
@testable import MKVSubtitleCore

/// Explicit opt-in only: normal CI does not use a login, quota, or private media.
/// Output contains subtitle text and must stay outside version control.
final class TranslationBatchBenchmarkTests: XCTestCase {
    func testOptInBatchBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SUB_BUDDY_BENCH_SOURCE"],
              let output = env["SUB_BUDDY_BENCH_OUTPUT"],
              let executable = env["SUB_BUDDY_CODEX_EXECUTABLE"] else {
            throw XCTSkip("Provide explicit benchmark source, output directory and Codex executable.")
        }
        let sizes = (env["SUB_BUDDY_BENCH_SIZES"] ?? "250,350,500").split(separator: ",").compactMap { Int($0) }
        let repeats = Int(env["SUB_BUDDY_BENCH_REPEATS"] ?? "2") ?? 2
        let languages = (env["SUB_BUDDY_BENCH_LANGUAGES"] ?? "zh-Hans").split(separator: ",").compactMap { SubtitleLanguage(rawValue: String($0)) }
        guard !sizes.isEmpty, sizes.allSatisfy({ (1...1000).contains($0) }),
              (1...3).contains(repeats), !languages.isEmpty else {
            XCTFail("Invalid benchmark configuration"); return
        }
        var source = try SubtitleParser().parse(contentsOf: URL(fileURLWithPath: input), format: .srt)
        if let limit = env["SUB_BUDDY_BENCH_CUE_LIMIT"].flatMap(Int.init), limit > 0 {
            source.cues = Array(source.cues.prefix(limit))
        }
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fingerprint = try SubtitleSourceIdentity.fingerprint(source)
        let model = env["SUB_BUDDY_BENCH_MODEL"] ?? CodexBridge.defaultModel
        let movie = MovieInfo(originalTitle: "Stuart Fails to Save the Universe S01E06")
        for repetition in 1...repeats {
            // Reverse order on the second pass to reduce (not eliminate) warm-cache/order bias.
            for size in repetition.isMultiple(of: 2) ? sizes.reversed().map({ $0 }) : sizes {
                for language in languages {
                    let prefix = "\(language.rawValue)-\(size)-r\(repetition)"
                    let resultURL = root.appendingPathComponent(prefix + ".json")
                    guard !FileManager.default.fileExists(atPath: resultURL.path) else {
                        XCTFail("Refusing to overwrite benchmark: \(prefix)"); return
                    }
                    let telemetry = BenchmarkExecutor()
                    let provider = BenchmarkProvider(
                        bridge: CodexBridge(codexURL: URL(fileURLWithPath: executable), model: model, executor: telemetry),
                        telemetry: telemetry, outputPrefix: root.appendingPathComponent(prefix))
                    let engine = TranslationEngine(provider: provider)
                    let chunks = TranslationChunker(configuration: .init(
                        targetCoreCount: size, maximumCoreCount: size,
                        maximumCoreCharacters: max(80_000, size * 300), contextCount: 50
                    )).chunks(for: source.cues)
                    let start = ContinuousClock.now
                    let startedAt = Date()
                    var firstSavedSeconds: Double?
                    var byID: [Int: String] = [:]
                    var glossary: [GlossaryEntry] = []
                    var repairs = 0
                    var failure: String?
                    var stopForServiceFailure = false
                    print("BENCH START \(prefix): \(source.cues.count) cues; \(chunks.count) chunks")
                    do {
                        for chunk in chunks {
                            let result = try await engine.translate(
                                chunk: chunk, movie: movie, glossary: glossary, targetLanguage: language,
                                onValidated: { response in
                                    if firstSavedSeconds == nil { firstSavedSeconds = start.duration(to: .now).seconds }
                                    for item in response.items { byID[item.id] = item.text }
                                    // Include actual serialization/disk cost; never reuse a preceding experiment.
                                    try JSONEncoder().encode(byID).write(to: root.appendingPathComponent(prefix + "-partial.json"), options: .atomic)
                                },
                                onRepair: { repairs += 1 }
                            )
                            glossary = TranslationGlossary.merge(glossary, result.glossaryUpdates)
                        }
                    } catch {
                        failure = error.localizedDescription
                        // Structural failures are benchmark outcomes: report them
                        // and proceed to the next size, but never keep requesting
                        // against exhausted quota, auth/network or storage errors.
                        if case AppError.invalidTranslation = error {
                            stopForServiceFailure = false
                        } else {
                            stopForServiceFailure = true
                        }
                    }
                    let calls = await provider.calls
                    var translated = source
                    if failure == nil {
                        do {
                            for index in translated.cues.indices {
                                translated.cues[index].text = try XCTUnwrap(byID[source.cues[index].id])
                            }
                            let url = root.appendingPathComponent(prefix + ".srt")
                            try SubtitleWriter().write(translated, to: url, overwrite: false)
                            let readBack = try SubtitleParser().parse(contentsOf: url, format: .srt)
                            guard readBack.cues.map(\.id) == source.cues.map(\.id),
                                  readBack.cues.map(\.startMilliseconds) == source.cues.map(\.startMilliseconds),
                                  readBack.cues.map(\.endMilliseconds) == source.cues.map(\.endMilliseconds) else {
                                throw AppError.invalidTranslation("Export round-trip changed IDs or timestamps")
                            }
                        } catch {
                            failure = "Export verification: \(error.localizedDescription)"
                            // Always preserve the measured generation result even
                            // if a malformed export fails the round-trip check.
                            stopForServiceFailure = error is CocoaError
                        }
                    }
                    let total = start.duration(to: .now).seconds
                    let report = BenchmarkReport(model: model, target: language.rawValue,
                        sourceFingerprint: fingerprint, sourceCues: source.cues.count,
                        sourceCharacters: source.cues.reduce(0) { $0 + $1.text.count },
                        batchLimit: size, repetition: repetition, startedAt: startedAt,
                        totalSeconds: total, firstSavedSeconds: firstSavedSeconds,
                        completedCues: byID.count, repairRounds: repairs, calls: calls, error: failure)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    try encoder.encode(report).write(to: resultURL, options: .atomic)
                    print("BENCH DONE \(prefix): \(String(format: "%.1f", total))s, \(calls.count) calls, \(repairs) repair rounds, \(byID.count)/\(source.cues.count) valid")
                    // Service/auth failures should stop, not consume the remaining matrix.
                    if let failure {
                        XCTFail("\(prefix): \(failure)")
                        if stopForServiceFailure { return }
                    }
                }
            }
        }
    }
}

private struct BenchmarkReport: Codable {
    let model: String
    let target: String
    let sourceFingerprint: String
    let sourceCues: Int
    let sourceCharacters: Int
    let batchLimit: Int
    let repetition: Int
    let startedAt: Date
    let totalSeconds: Double
    let firstSavedSeconds: Double?
    let completedCues: Int
    let repairRounds: Int
    let calls: [BenchmarkCall]
    let error: String?
}

private struct BenchmarkCall: Codable {
    let coreCues: Int
    let promptCharacters: Int
    let promptSHA256: String
    let outputCharacters: Int
    let validCues: Int
    let seconds: Double
    let usage: [String: Int]
}

private actor BenchmarkProvider: TranslationProvider {
    nonisolated let requiresSourceEcho = true
    let bridge: CodexBridge
    let telemetry: BenchmarkExecutor
    let outputPrefix: URL
    var calls: [BenchmarkCall] = []
    init(bridge: CodexBridge, telemetry: BenchmarkExecutor, outputPrefix: URL) {
        self.bridge = bridge
        self.telemetry = telemetry
        self.outputPrefix = outputPrefix
    }
    func translate(_ request: TranslationRequest) async throws -> String {
        let prompt = TranslationPromptBuilder().build(request)
        let start = ContinuousClock.now
        let raw = try await bridge.executeTranslation(prompt: prompt)
        try Data(raw.utf8).write(to: URL(fileURLWithPath: outputPrefix.path + "-call-\(calls.count + 1).txt"), options: .atomic)
        let valid = try? TranslationValidator().alignedPartial(rawJSON: raw, expectedCues: request.chunk.core, requiresSourceEcho: true)
        calls.append(BenchmarkCall(coreCues: request.chunk.core.count,
            promptCharacters: prompt.count,
            promptSHA256: SHA256.hash(data: Data(prompt.utf8)).map { String(format: "%02x", $0) }.joined(),
            outputCharacters: raw.count, validCues: valid?.items.count ?? 0,
            seconds: start.duration(to: .now).seconds, usage: await telemetry.lastUsage))
        try JSONEncoder().encode(calls).write(to: URL(fileURLWithPath: outputPrefix.path + "-calls.json"), options: .atomic)
        print("BENCH CALL \(request.chunk.core.count) cues: \(String(format: "%.1f", calls.last!.seconds))s, valid \(valid?.items.count ?? 0)")
        return raw
    }
}

/// Extract only numeric token counters, never account/authentication data or CLI logs.
private actor BenchmarkExecutor: ProcessExecuting {
    var lastUsage: [String: Int] = [:]
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        lastUsage = [:]
        let result = try await ProcessExecutor().run(executable: executable, arguments: arguments, standardInput: standardInput)
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  event["type"] as? String == "turn.completed",
                  let usage = event["usage"] as? [String: Int] else { continue }
            lastUsage = usage
        }
        return result
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
