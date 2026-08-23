import XCTest
@testable import MKVSubtitleCore

final class ChunkerValidatorTests: XCTestCase {
    func testTranslationTextProtectorRestoresLineBreaksHTMLAndASSTags() throws {
        let original = "<i>Hello</i>\n{\\an8}World"
        let protected = TranslationTextProtector().protect(original)

        XCTAssertFalse(protected.sourceText.contains("<i>"))
        XCTAssertFalse(protected.sourceText.contains("\n"))
        XCTAssertEqual(try protected.restore(protected.sourceText), original)
        XCTAssertThrowsError(try protected.restore("translated without markers"))
    }

    private func cues(_ count: Int) -> [SubtitleCue] {
        (1...count).map { SubtitleCue(id: $0, startMilliseconds: Int64($0 * 1_000), endMilliseconds: Int64($0 * 1_000 + 900), text: "Line \($0)") }
    }

    func testTenSupportedLanguagesHaveMetadataAndAliases() {
        XCTAssertEqual(SubtitleLanguage.allCases.count, 10)
        XCTAssertTrue(SubtitleLanguage.english.matches("eng"))
        XCTAssertTrue(SubtitleLanguage.simplifiedChinese.matches("chi"))
        XCTAssertTrue(SubtitleLanguage.portuguese.matches("pt-BR"))
        XCTAssertEqual(SubtitleLanguage.japanese.iso6392Code, "jpn")
    }

    func testLanguageMatchingAcceptsRegionalAndUnderscoreTagsWithoutCrossLanguageMatches() {
        XCTAssertTrue(SubtitleLanguage.english.matches("en-US"))
        XCTAssertTrue(SubtitleLanguage.english.matches("ENG-us"))
        XCTAssertTrue(SubtitleLanguage.spanish.matches("es-419"))
        XCTAssertTrue(SubtitleLanguage.simplifiedChinese.matches("zh_Hans_CN"))
        XCTAssertTrue(SubtitleLanguage.portuguese.matches("pt_BR"))
        XCTAssertFalse(SubtitleLanguage.english.matches("de-DE"))
        XCTAssertFalse(SubtitleLanguage.simplifiedChinese.matches("ja-JP"))
    }

    func testTenIndependentInterfaceLanguagesAreAvailable() {
        XCTAssertEqual(AppInterfaceLanguage.allCases.count, 10)
        XCTAssertEqual(AppInterfaceLanguage.english.nativeName, "English")
        XCTAssertEqual(AppInterfaceLanguage.japanese.locale.identifier, "ja")
        XCTAssertEqual(AppInterfaceLanguage.arabic.rawValue, "ar")
    }

    func testLanguageAwareOutputNamesAvoidCrossLanguageOverwrite() {
        XCTAssertEqual(
            SubtitleOutputMode.pureChinese.sidecarFileSuffix(targetLanguage: .simplifiedChinese),
            ""
        )
        XCTAssertEqual(
            SubtitleOutputMode.pureChinese.sidecarFileSuffix(targetLanguage: .french),
            "_fr"
        )
        XCTAssertEqual(
            SubtitleOutputMode.bilingual.sidecarFileSuffix(targetLanguage: .japanese),
            "_ja_bilingual"
        )
        XCTAssertEqual(
            SubtitleOutputMode.pureChinese.muxFileSuffix(targetLanguage: .simplifiedChinese),
            "_zh"
        )
        XCTAssertEqual(
            SubtitleOutputMode.bilingual.trackTitle(sourceLanguage: .english, targetLanguage: .korean),
            "韩语 + 英语"
        )
    }

    func testPromptUsesSelectedSourceAndTargetLanguages() {
        let request = TranslationRequest(
            chunk: TranslationChunk(index: 0, core: cues(1), previousContext: [], nextContext: []),
            movie: MovieInfo(originalTitle: "Demo"),
            glossary: [],
            sourceLanguage: .japanese,
            targetLanguage: .french
        )
        let prompt = TranslationPromptBuilder().build(request)
        XCTAssertTrue(prompt.contains("Japanese（日语）"))
        XCTAssertTrue(prompt.contains("French（法语）"))
    }

    func testChunkingCoreAndOverlappingContext() {
        let chunker = TranslationChunker(configuration: .init(targetCoreCount: 45, maximumCoreCount: 60, maximumCoreCharacters: 99_999, contextCount: 10))
        let chunks = chunker.chunks(for: cues(130))
        XCTAssertEqual(chunks.map { $0.core.count }, [45, 45, 40])
        XCTAssertEqual(chunks[0].previousContext.count, 0)
        XCTAssertEqual(chunks[0].nextContext.map(\.id), Array(46...55))
        XCTAssertEqual(chunks[1].previousContext.map(\.id), Array(36...45))
        XCTAssertEqual(chunks[1].nextContext.map(\.id), Array(91...100))
        XCTAssertEqual(chunks[2].nextContext.count, 0)
        XCTAssertEqual(chunks.flatMap(\.core).map(\.id), Array(1...130))
    }

    func testDefaultChunkingUsesFiveHundredCoreCuesAndFiftyContextCues() {
        let chunks = TranslationChunker().chunks(for: cues(1_200))
        XCTAssertEqual(chunks.map { $0.core.count }, [500, 500, 200])
        XCTAssertEqual(chunks[0].nextContext.map(\.id), Array(501...550))
        XCTAssertEqual(chunks[1].previousContext.map(\.id), Array(451...500))
        XCTAssertEqual(chunks[1].nextContext.map(\.id), Array(1001...1050))
        XCTAssertEqual(chunks[2].previousContext.map(\.id), Array(951...1000))
    }

    func testSubtitleOutputComposerSupportsPureChineseAndBilingualFormats() {
        let composer = SubtitleOutputComposer()
        XCTAssertEqual(
            composer.text(chinese: "你好", english: "Hello", format: .srt, mode: .pureChinese),
            "你好"
        )
        XCTAssertEqual(
            composer.text(chinese: "你好", english: "Hello", format: .srt, mode: .bilingual),
            "你好\nHello"
        )
        XCTAssertEqual(
            composer.text(chinese: "你好", english: "Hello", format: .ass, mode: .bilingual),
            "你好\\NHello"
        )
    }

    func testChunkingAlsoHonorsCharacterLimit() {
        let longCues = (1...5).map { SubtitleCue(id: $0, startMilliseconds: 0, endMilliseconds: 1, text: String(repeating: "x", count: 8)) }
        let chunks = TranslationChunker(configuration: .init(targetCoreCount: 5, maximumCoreCount: 60, maximumCoreCharacters: 17, contextCount: 1)).chunks(for: longCues)
        XCTAssertEqual(chunks.map { $0.core.count }, [2, 2, 1])
    }

    func testValidatorAcceptsExactIDs() throws {
        let raw = #"{"items":[{"id":1,"text":"一"},{"id":2,"text":"二"}],"glossary_updates":[]}"#
        let result = try TranslationValidator().validate(rawJSON: raw, expectedIDs: [1, 2])
        XCTAssertEqual(result.items.count, 2)
    }

    func testValidatorRejectsDuplicateMissingAndExtraIDs() {
        let validator = TranslationValidator()
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":"一"},{"id":1,"text":"重复"}]}"#, expectedIDs: [1, 2]))
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":"一"}]}"#, expectedIDs: [1, 2]))
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":"一"},{"id":3,"text":"三"}]}"#, expectedIDs: [1, 2]))
        XCTAssertThrowsError(try validator.validate(rawJSON: "说明：\n" + #"{"items":[{"id":1,"text":"一"}]}"#, expectedIDs: [1]))
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":""}]}"#, expectedIDs: [1]))
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":"一","note":"解释"}]}"#, expectedIDs: [1]))
        XCTAssertThrowsError(try validator.validate(rawJSON: #"{"items":[{"id":1,"text":"一"}],"explanation":"完成"}"#, expectedIDs: [1]))
    }

    func testMalformedFirstResponseTriggersOneRepair() async throws {
        let provider = MockTranslationProvider(mode: .malformedThenSuccess)
        let chunk = TranslationChunk(index: 0, core: cues(2), previousContext: [], nextContext: [])
        let result = try await TranslationEngine(provider: provider).translate(
            chunk: chunk,
            movie: MovieInfo(originalTitle: "Demo"),
            glossary: []
        )
        XCTAssertEqual(result.items.map(\.id), [1, 2])
        let calls = await provider.numberOfCalls()
        XCTAssertEqual(calls, 2)
    }

    func testLargeValidResponseRepairsOnlyMissingTailAndMergesIt() async throws {
        let provider = MissingTailProvider()
        let chunk = TranslationChunk(index: 0, core: cues(500), previousContext: [], nextContext: [])
        let result = try await TranslationEngine(provider: provider).translate(
            chunk: chunk,
            movie: MovieInfo(originalTitle: "Demo"),
            glossary: []
        )
        XCTAssertEqual(result.items.map(\.id), Array(1...500))
        let requestedIDs = await provider.requestedIDs()
        XCTAssertEqual(requestedIDs, [Array(1...500), Array(497...500)])
    }

    func testTruncatedLargeJSONRecoversInBoundedBatches() async throws {
        let provider = TruncatedLargeProvider()
        let chunk = TranslationChunk(index: 0, core: cues(500), previousContext: [], nextContext: [])
        let result = try await TranslationEngine(provider: provider).translate(
            chunk: chunk,
            movie: MovieInfo(originalTitle: "Demo"),
            glossary: []
        )
        XCTAssertEqual(result.items.map(\.id), Array(1...500))
        let requestedIDs = await provider.requestedIDs()
        XCTAssertEqual(requestedIDs, [
            Array(1...500), Array(1...250), Array(251...500)
        ])
    }
}

private actor MissingTailProvider: TranslationProvider {
    private var requests: [[Int]] = []

    func translate(_ request: TranslationRequest) async throws -> String {
        let ids = request.chunk.core.map(\.id)
        requests.append(ids)
        let outputIDs = requests.count == 1 ? Array(ids.prefix(496)) : ids
        let response = TranslationResponse(items: outputIDs.map { TranslationItem(id: $0, text: "译文 \($0)") })
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    func requestedIDs() -> [[Int]] { requests }
}

private actor TruncatedLargeProvider: TranslationProvider {
    private var requests: [[Int]] = []

    func translate(_ request: TranslationRequest) async throws -> String {
        let ids = request.chunk.core.map(\.id)
        requests.append(ids)
        if requests.count == 1 { return #"{"items":[{"id":1,"text":"未结束"}"# }
        let response = TranslationResponse(items: ids.map { TranslationItem(id: $0, text: "译文 \($0)") })
        return String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    func requestedIDs() -> [[Int]] { requests }
}
