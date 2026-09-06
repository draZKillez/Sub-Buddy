import Foundation
import XCTest
@testable import MKVSubtitleCore

final class SubtitleExportWhitespaceTests: XCTestCase {
    func testBlankBodyLinesCannotBreakFollowingCueInSRTOrVTT() throws {
        for format in [SubtitleFormat.srt, .webVTT] {
            let document = SubtitleDocument(format: format, cues: [
                .init(id: 389, startMilliseconds: 1000, endMilliseconds: 2000,
                      text: "\r\n<i>事实上</i>\r\n \t\r\n  第二行  \r\n"),
                .init(id: 390, startMilliseconds: 2100, endMilliseconds: 3100, text: "Next cue")
            ])
            let text = try SubtitleWriter().string(from: document)
            let reparsed = try SubtitleParser().parse(data: Data(text.utf8), format: format)
            XCTAssertEqual(reparsed.cues.count, 2)
            XCTAssertEqual(reparsed.cues[0].text, "<i>事实上</i>\n  第二行  ")
            XCTAssertEqual(reparsed.cues[1].text, "Next cue")
            XCTAssertEqual(reparsed.cues.map(\.startMilliseconds), document.cues.map(\.startMilliseconds))
            XCTAssertEqual(reparsed.cues.map(\.endMilliseconds), document.cues.map(\.endMilliseconds))
        }
    }

    func testEmptyCueFailsBeforeWritingAnyInvalidOutput() {
        for format in [SubtitleFormat.srt, .webVTT] {
            for text in [" \n\t\r\n", "\u{2028}", "\u{0085}", ""] {
                let document = SubtitleDocument(format: format, cues: [
                    .init(id: 1, startMilliseconds: 1000, endMilliseconds: 2000, text: text)
                ])
                XCTAssertThrowsError(try SubtitleWriter().string(from: document))
            }
        }
    }

    func testOptInOfflineReplayOfSavedBenchmark() throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["SUB_BUDDY_REPLAY_SOURCE"],
              let partial = env["SUB_BUDDY_REPLAY_PARTIAL"],
              let output = env["SUB_BUDDY_REPLAY_OUTPUT"] else {
            throw XCTSkip("Offline replay requires explicit source, saved translations and output.")
        }
        var document = try SubtitleParser().parse(contentsOf: URL(fileURLWithPath: input), format: .srt)
        let original = document
        let saved = try JSONDecoder().decode([Int: String].self, from: Data(contentsOf: URL(fileURLWithPath: partial)))
        XCTAssertEqual(Set(saved.keys), Set(document.cues.map(\.id)))
        for index in document.cues.indices { document.cues[index].text = try XCTUnwrap(saved[document.cues[index].id]) }
        let url = URL(fileURLWithPath: output)
        try SubtitleWriter().write(document, to: url, overwrite: false)
        let result = try SubtitleParser().parse(contentsOf: url, format: .srt)
        XCTAssertEqual(result.cues.map(\.id), original.cues.map(\.id))
        XCTAssertEqual(result.cues.map(\.startMilliseconds), original.cues.map(\.startMilliseconds))
        XCTAssertEqual(result.cues.map(\.endMilliseconds), original.cues.map(\.endMilliseconds))
    }
}
