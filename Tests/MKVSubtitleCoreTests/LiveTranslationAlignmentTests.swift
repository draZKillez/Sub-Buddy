import Foundation
import XCTest
@testable import MKVSubtitleCore

/// Explicit opt-in integration check. Ordinary test runs never call Codex or
/// read a user's media; paths must be supplied by the person running this test.
final class LiveTranslationAlignmentTests: XCTestCase {
    func testOptInRealSubtitleTranslation() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SUB_BUDDY_LIVE_SOURCE"],
              let output = env["SUB_BUDDY_LIVE_OUTPUT"],
              let executable = env["SUB_BUDDY_CODEX_EXECUTABLE"] else {
            throw XCTSkip("Live Codex check requires explicit input, output and executable paths.")
        }
        let source = try SubtitleParser().parse(contentsOf: URL(fileURLWithPath: input), format: .srt)
        var translated = source
        var byID: [Int: String] = [:]
        let bridge = CodexBridge(codexURL: URL(fileURLWithPath: executable))
        let engine = TranslationEngine(provider: CodexTranslationProvider(bridge: bridge))
        var glossary: [GlossaryEntry] = []
        for chunk in TranslationChunker().chunks(for: source.cues) {
            let response = try await engine.translate(
                chunk: chunk, movie: .init(originalTitle: "Stuart Fails to Save the Universe S01E06"), glossary: glossary
            )
            for item in response.items { byID[item.id] = item.text }
            glossary = TranslationGlossary.merge(glossary, response.glossaryUpdates)
        }
        for index in translated.cues.indices {
            translated.cues[index].text = try XCTUnwrap(byID[translated.cues[index].id])
        }
        let outputURL = URL(fileURLWithPath: output)
        try SubtitleWriter().write(translated, to: outputURL, overwrite: false)
        let reparsed = try SubtitleParser().parse(contentsOf: outputURL, format: .srt)
        XCTAssertEqual(reparsed.cues.count, source.cues.count)
        XCTAssertEqual(reparsed.cues.map(\.startMilliseconds), source.cues.map(\.startMilliseconds))
        XCTAssertEqual(reparsed.cues.map(\.endMilliseconds), source.cues.map(\.endMilliseconds))
    }
}
