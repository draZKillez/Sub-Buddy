import Foundation
import XCTest
@testable import MKVSubtitleCore

final class TranslationAlignmentTests: XCTestCase {
    private var cues: [SubtitleCue] {
        [
            SubtitleCue(id: 247, startMilliseconds: 778_111, endMilliseconds: 779_904, text: "Let me explain"),
            SubtitleCue(id: 248, startMilliseconds: 780_488, endMilliseconds: 781_739, text: "in simple terms."),
            SubtitleCue(id: 249, startMilliseconds: 782_782, endMilliseconds: 784_533, text: "A different sentence.")
        ]
    }

    func testShiftedSourceFailsEvenWhenEveryIDIsPresent() throws {
        let raw = #"{"items":[{"id":247,"source":"Let me explain","text":"让我解释一下"},{"id":248,"source":"A different sentence.","text":"另一个句子"},{"id":249,"source":"in simple terms.","text":"简单地说"}]}"#
        // Old count/ID validation accepts this; source binding retains only 247.
        XCTAssertEqual(try TranslationValidator().validate(rawJSON: raw, expectedIDs: [247, 248, 249]).items.count, 3)
        let partial = try TranslationValidator().alignedPartial(rawJSON: raw, expectedCues: cues, requiresSourceEcho: true)
        XCTAssertEqual(partial.items.map(\.id), [247])
    }

    func testSourceEchoIsRequiredOnlyForGenerativeProviders() throws {
        let raw = #"{"items":[{"id":247,"text":"让我解释一下"}]}"#
        let validator = TranslationValidator()
        XCTAssertTrue(try validator.alignedPartial(rawJSON: raw, expectedCues: cues, requiresSourceEcho: true).items.isEmpty)
        XCTAssertEqual(try validator.alignedPartial(rawJSON: raw, expectedCues: cues, requiresSourceEcho: false).items.count, 1)
    }

    func testDuplicatedIDIsNeverArbitrarilySelectedDuringRecovery() throws {
        let raw = #"{"items":[{"id":247,"text":"甲"},{"id":247,"text":"乙"},{"id":248,"text":"简单地说"}]}"#
        XCTAssertEqual(try TranslationValidator().alignedPartial(rawJSON: raw, expectedCues: cues, requiresSourceEcho: false).items.map(\.id), [248])
    }

    func testEscapedLineBreakRepairDoesNotCorruptPathsOrRealNewlines() {
        let normalize = TranslationValidator.normalizeLineBreaks
        XCTAssertEqual(normalize(#"第一行\n第二行"#, "First\nSecond"), "第一行\n第二行")
        XCTAssertEqual(normalize(#"第一行\r\n第二行"#, "First\nSecond"), "第一行\n第二行")
        XCTAssertEqual(normalize(#"C:\new\notes"#, #"C:\new\notes"#), #"C:\new\notes"#)
        XCTAssertEqual(normalize("A\nB", "First\nSecond"), "A\nB")
        XCTAssertEqual(normalize(#"literal \n"#, "single line"), #"literal \n"#)
    }

    func testSourceFingerprintChangesWithTextOrTimestampButNotChunkSize() throws {
        let document = SubtitleDocument(format: .srt, cues: cues)
        let fingerprint = try SubtitleSourceIdentity.fingerprint(document)
        XCTAssertEqual(fingerprint, try SubtitleSourceIdentity.fingerprint(document))
        var changed = document
        changed.cues[0].text = "Different original"
        XCTAssertNotEqual(fingerprint, try SubtitleSourceIdentity.fingerprint(changed))
        changed = document
        changed.cues[0].startMilliseconds += 1
        XCTAssertNotEqual(fingerprint, try SubtitleSourceIdentity.fingerprint(changed))
    }

    func testRecoveryStopsAfterTwoRoundsAndRetainsOnlyValidatedItems() async throws {
        let provider = AlignmentProvider(failingID: 248)
        var saved: [Int: String] = [:]
        do {
            _ = try await TranslationEngine(provider: provider).translate(
                chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
                movie: .init(originalTitle: "Test"), glossary: [],
                onValidated: { response in
                    for item in response.items { saved[item.id] = item.text }
                }
            )
            XCTFail("Unresolved source mismatch must stop")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("248"))
        }
        XCTAssertEqual(Set(saved.keys), [247, 249])
        let requests = await provider.requests
        XCTAssertEqual(requests, [[247, 248, 249], [248], [248]])

        let retry = AlignmentProvider(failingID: nil)
        let result = try await TranslationEngine(provider: retry).translate(
            chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
            movie: .init(originalTitle: "Test"), glossary: [], completedItems: saved
        )
        let retryRequests = await retry.requests
        XCTAssertEqual(retryRequests, [[248]])
        XCTAssertEqual(result.items.map(\.id), [247, 248, 249])
    }

    func testStorageFailureIsNotRetriedAsTranslationFailure() async throws {
        let provider = AlignmentProvider(failingID: nil)
        do {
            _ = try await TranslationEngine(provider: provider).translate(
                chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
                movie: .init(originalTitle: "Test"), glossary: [],
                onValidated: { _ in throw CocoaError(.fileWriteOutOfSpace) }
            )
            XCTFail("Storage error must be surfaced")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue)
        }
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testPipelinePersistsPartialChunkAndResumesWithoutChangingTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Alignment-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Test.mkv")
        try Data().write(to: input)
        let output = root.appendingPathComponent("Test.srt")
        let document = SubtitleDocument(format: .srt, cues: cues)
        let ffmpeg = FFmpegService(ffmpegURL: URL(fileURLWithPath: "/unused"), executor: AlignmentExtraction(document: document))
        let store = JobStore(rootURL: root.appendingPathComponent("Jobs"))
        let track = SubtitleTrack(streamIndex: 2, codec: "subrip", language: "eng", title: "", isDefault: false, isForced: false, isSDH: false, isText: true)
        let movie = MovieInfo(originalTitle: "Test")
        do {
            _ = try await TranslationPipeline(ffmpeg: ffmpeg, provider: AlignmentProvider(failingID: 248), jobStore: store)
                .run(input: input, track: track, movie: movie, output: output, existingSubtitleCount: 1, overwrite: false) { _ in }
            XCTFail("First attempt should fail at 248")
        } catch { XCTAssertTrue(error.localizedDescription.contains("248")) }
        let saved = try await store.load(input: input, trackIndex: 2)
        XCTAssertEqual(Set(saved?.translatedItems.keys.map { $0 } ?? []), [247, 249])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let provider = AlignmentProvider(failingID: nil)
        _ = try await TranslationPipeline(ffmpeg: ffmpeg, provider: provider, jobStore: store)
            .run(input: input, track: track, movie: movie, output: output, existingSubtitleCount: 1, overwrite: false) { _ in }
        let requests = await provider.requests
        XCTAssertEqual(requests, [[248]])
        let result = try SubtitleParser().parse(contentsOf: output, format: .srt)
        XCTAssertEqual(result.cues.map(\.id), cues.map(\.id))
        XCTAssertEqual(result.cues.map(\.startMilliseconds), cues.map(\.startMilliseconds))
        XCTAssertEqual(result.cues.map(\.endMilliseconds), cues.map(\.endMilliseconds))
    }

    func testGlossaryMergeCapsSizeAndReplacesCaseInsensitiveDuplicate() {
        let terms = (1...600).map { GlossaryEntry(source: "Name \($0)", target: "译名 \($0)") }
        let merged = TranslationGlossary.merge(terms, [.init(source: "NAME 600", target: "新译名")])
        XCTAssertEqual(merged.count, 500)
        XCTAssertEqual(merged.last?.target, "新译名")
    }
}

private actor AlignmentProvider: TranslationProvider {
    nonisolated let requiresSourceEcho = true
    let failingID: Int?
    var requests: [[Int]] = []
    init(failingID: Int?) { self.failingID = failingID }
    func translate(_ request: TranslationRequest) async throws -> String {
        requests.append(request.chunk.core.map(\.id))
        let items = request.chunk.core.reversed().map {
            TranslationItem(id: $0.id, text: "译文 \($0.id)", source: $0.id == failingID ? "Wrong neighboring source" : $0.text)
        }
        return String(decoding: try JSONEncoder().encode(TranslationResponse(items: items)), as: UTF8.self)
    }
}

private struct AlignmentExtraction: ProcessExecuting {
    let document: SubtitleDocument
    func run(executable: URL, arguments: [String], standardInput: Data?) async throws -> ProcessResult {
        try SubtitleWriter().write(document, to: URL(fileURLWithPath: arguments.last!))
        return .init(status: 0, standardOutput: "", standardError: "")
    }
}
