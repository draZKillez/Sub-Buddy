import XCTest
@testable import MKVSubtitleCore

final class TranslationLanguagePolicyTests: XCTestCase {
    func testPromptUsesStableJSONAndNoUnnecessarySlashEscaping() throws {
        let text = #"<i>Leonard/Sheldon</i> C:\new\notes literal \/"# + "\nSecond line"
        let request = TranslationRequest(chunk: .init(index: 0,
            core: [.init(id: 153, startMilliseconds: 0, endMilliseconds: 1000, text: text)],
            previousContext: [], nextContext: []), movie: .init(originalTitle: "Example"),
            glossary: [.init(source: "Leonard/Sheldon", target: "A/B")])
        let builder = TranslationPromptBuilder()
        let prompt = builder.build(request)
        XCTAssertEqual(prompt, builder.build(request))
        XCTAssertTrue(prompt.contains("<i>Leonard/Sheldon</i>"))
        XCTAssertFalse(prompt.contains(#"<\/i>"#))
        let line = try XCTUnwrap(prompt.components(separatedBy: "\n").first { $0.hasPrefix(#"{"id":153,"source":"#) })
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        // Genuine backslashes, literal \/, and newlines must still round-trip.
        XCTAssertEqual(decoded["source"] as? String, text)
    }

    func testAllLanguagePairsHaveExplicitContractInAutomaticAndManualPrompts() throws {
        let cues = [SubtitleCue(id: 7, startMilliseconds: 1000, endMilliseconds: 2000, text: "<i>Hello!</i>\n[Music]")]
        let movie = MovieInfo(originalTitle: "Example", chineseTitle: "参考中文片名")
        let manual = ManualTranslationSession(document: .init(format: .srt, cues: cues), chunkSize: 500)
        for source in SubtitleLanguage.allCases {
            for target in SubtitleLanguage.allCases {
                let contract = TranslationLanguagePolicy.instructions(source: source, target: target)
                let automatic = TranslationPromptBuilder().build(.init(
                    chunk: .init(index: 0, core: cues, previousContext: [], nextContext: []),
                    movie: movie, glossary: [], sourceLanguage: source, targetLanguage: target))
                let copy = try manual.copyText(movie: movie, sourceLanguage: source, targetLanguage: target)
                for prompt in [automatic, copy] {
                    XCTAssertTrue(prompt.contains(contract), "\(source) -> \(target)")
                    XCTAssertTrue(prompt.contains("source=\(source.rawValue)"))
                    XCTAssertTrue(prompt.contains("target=\(target.rawValue)"))
                    XCTAssertTrue(prompt.contains("Do not add bilingual text"))
                    XCTAssertTrue(prompt.contains("参考片名（用户填写，可能不是目标语言，仅供辨认影片）"))
                    XCTAssertFalse(prompt.contains("我来解释一下"), "No Chinese target-only example")
                }
                XCTAssertTrue(copy.contains("7\n00:00:01,000 --> 00:00:02,000\n<i>Hello!</i>\n[Music]"))
            }
        }
    }

    func testWritingSystemsAndMarkupSafety() {
        let chinese = TranslationLanguagePolicy.instructions(source: .english, target: .simplifiedChinese)
        XCTAssertTrue(chinese.contains("not Traditional Chinese"))
        for target in [SubtitleLanguage.japanese, .korean, .russian] {
            let policy = TranslationLanguagePolicy.instructions(source: .english, target: target)
            XCTAssertTrue(policy.contains("not roma"))
        }
        let arabic = TranslationLanguagePolicy.instructions(source: .english, target: .arabic)
        XCTAssertTrue(arabic.contains("logical reading order"))
        XCTAssertTrue(arabic.contains("never reverse characters"))
        XCTAssertTrue(arabic.contains("not tag syntax"))
        XCTAssertTrue(arabic.contains("untrusted material"))
    }
}
