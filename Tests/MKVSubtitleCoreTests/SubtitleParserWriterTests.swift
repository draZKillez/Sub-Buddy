import XCTest
@testable import MKVSubtitleCore

final class SubtitleParserWriterTests: XCTestCase {
    func testSRTRejectsEmptyMalformedAndDuplicateCueIDs() {
        let parser = SubtitleParser()
        XCTAssertThrowsError(try parser.parse(data: Data(), format: .srt))

        let malformedMiddleCue = """
        1
        00:00:01,000 --> 00:00:02,000
        First

        2
        not a timeline
        This cue must not be silently dropped

        3
        00:00:03,000 --> 00:00:04,000
        Third
        """
        XCTAssertThrowsError(try parser.parse(data: Data(malformedMiddleCue.utf8), format: .srt))

        let duplicateIDs = """
        1
        00:00:01,000 --> 00:00:02,000
        First

        1
        00:00:03,000 --> 00:00:04,000
        Duplicate
        """
        XCTAssertThrowsError(try parser.parse(data: Data(duplicateIDs.utf8), format: .srt))
    }

    func testSRTRejectsMissingIDEmptyBodyAndBackwardTimeline() {
        let parser = SubtitleParser()
        let invalidDocuments = [
            "00:00:01,000 --> 00:00:02,000\nMissing ID\n",
            "1\n00:00:01,000 --> 00:00:02,000\n",
            "1\n00:00:02,000 --> 00:00:01,000\nBackwards\n"
        ]
        for source in invalidDocuments {
            XCTAssertThrowsError(try parser.parse(data: Data(source.utf8), format: .srt), source)
        }
    }

    func testSRTAcceptsWhitespaceOnBlankSeparatorLines() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nFirst\n   \n2\n00:00:03,000 --> 00:00:04,000\nSecond\n"
        let document = try SubtitleParser().parse(data: Data(text.utf8), format: .srt)
        XCTAssertEqual(document.cues.map(\.id), [1, 2])
    }

    func testSRTParsingWritingAndTimelinePreservation() throws {
        let source = """
        1
        00:00:01,250 --> 00:00:03,500
        <i>Hello</i>
        world

        2
        01:02:03,004 --> 01:02:05,006
        [door opens]
        """
        let parser = SubtitleParser()
        let document = try parser.parse(data: Data(source.utf8), format: .srt)
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.cues[0].startMilliseconds, 1_250)
        XCTAssertEqual(document.cues[0].endMilliseconds, 3_500)
        XCTAssertEqual(document.cues[0].text, "<i>Hello</i>\nworld")
        XCTAssertEqual(document.cues[1].startMilliseconds, 3_723_004)

        let output = try SubtitleWriter().string(from: document)
        let reparsed = try parser.parse(data: Data(output.utf8), format: .srt)
        XCTAssertEqual(reparsed.cues.map(\.startMilliseconds), document.cues.map(\.startMilliseconds))
        XCTAssertEqual(reparsed.cues.map(\.endMilliseconds), document.cues.map(\.endMilliseconds))
        XCTAssertEqual(reparsed.cues.map(\.text), document.cues.map(\.text))
    }

    func testSRTWithUTF8BOMDoesNotLoseFirstCue() throws {
        let source = "\u{FEFF}1\n00:00:51,969 --> 00:00:54,388\n-Hey, Stuart.\n-Bert.\n\n2\n00:00:55,055 --> 00:00:56,265\nGot anything new?\n"
        let document = try SubtitleParser().parse(data: Data(source.utf8), format: .srt)

        XCTAssertEqual(document.cues.map(\.id), [1, 2])
        XCTAssertEqual(document.cues.first?.text, "-Hey, Stuart.\n-Bert.")
        XCTAssertEqual(document.cues.first?.startMilliseconds, 51_969)
    }

    func testASSParsingWritingPreservesTimelineFieldsAndTags() throws {
        let source = """
        [Script Info]
        Title: Demo

        [V4+ Styles]
        Format: Name, Fontname, Fontsize
        Style: Default,Arial,20

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.25,0:00:03.50,Default,John,0000,0000,0000,,{\\i1}Hello, world{\\i0}\\NNext
        Dialogue: 0,1:02:03.04,1:02:05.06,Default,,0000,0000,0000,,[door opens]
        """
        let parser = SubtitleParser()
        var document = try parser.parse(data: Data(source.utf8), format: .ass)
        XCTAssertEqual(document.cues.count, 2)
        XCTAssertEqual(document.cues[0].startMilliseconds, 1_250)
        XCTAssertEqual(document.cues[0].text, "{\\i1}Hello, world{\\i0}\\NNext")
        document.cues[0].text = "{\\i1}你好，世界{\\i0}\\N下一行"

        let output = try SubtitleWriter().string(from: document)
        XCTAssertTrue(output.contains("Style: Default,Arial,20"))
        XCTAssertTrue(output.contains("{\\i1}你好，世界{\\i0}\\N下一行"))
        let reparsed = try parser.parse(data: Data(output.utf8), format: .ass)
        XCTAssertEqual(reparsed.cues.map(\.startMilliseconds), document.cues.map(\.startMilliseconds))
        XCTAssertEqual(reparsed.cues.map(\.endMilliseconds), document.cues.map(\.endMilliseconds))
        XCTAssertEqual(reparsed.cues[0].assFields, document.cues[0].assFields)
    }

    func testASSRejectsMalformedDialogueInsteadOfSilentlyDroppingIt() {
        let source = """
        [Script Info]
        Title: Demo

        [Events]
        Format: Layer, Start, End, Style, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,First
        Dialogue: 0,not-a-time,0:00:04.00,Default,Broken
        """
        XCTAssertThrowsError(try SubtitleParser().parse(data: Data(source.utf8), format: .ass))
    }

    func testASSSupportsTextFieldBeforeTrailingFieldsAndLeavesEventsAtNextSection() throws {
        let source = """
        [Events]
        Format: Layer, Start, End, Text, Effect
        Dialogue: 0,0:00:01.00,0:00:02.00,Hello, world,fade

        [Fonts]
        Dialogue: this is font payload, not an Events cue
        """
        let parser = SubtitleParser()
        let document = try parser.parse(data: Data(source.utf8), format: .ass)
        XCTAssertEqual(document.cues.count, 1)
        XCTAssertEqual(document.cues[0].text, "Hello, world")
        XCTAssertEqual(document.cues[0].assFields?.last, "fade")

        let written = try SubtitleWriter().string(from: document)
        let dialogue = "Dialogue: 0,0:00:01.00,0:00:02.00,Hello, world,fade"
        XCTAssertTrue(written.contains(dialogue))
        let dialogueIndex = try XCTUnwrap(written.range(of: dialogue)?.lowerBound)
        let fontsIndex = try XCTUnwrap(written.range(of: "[Fonts]")?.lowerBound)
        XCTAssertLessThan(
            dialogueIndex,
            fontsIndex,
            "Written ASS dialogue must remain inside the [Events] section"
        )
    }

    func testASSWriterMissingStartOrEndThrowsInsteadOfCrashing() {
        let cue = SubtitleCue(
            id: 1,
            startMilliseconds: 1_000,
            endMilliseconds: 2_000,
            text: "Hello",
            assFields: ["0"]
        )
        for fields in [["layer", "text"], ["start", "text"], ["end", "text"]] {
            let document = SubtitleDocument(
                format: .ass,
                cues: [cue],
                assHeader: "[Events]\nFormat: \(fields.joined(separator: ", "))",
                assFormatFields: fields
            )
            XCTAssertThrowsError(try SubtitleWriter().string(from: document), "Fields: \(fields)")
        }
    }

    func testWebVTTParsingIsSupported() throws {
        let source = "WEBVTT\n\n1\n00:00:01.000 --> 00:00:02.500 align:start\nHello\n"
        let document = try SubtitleParser().parse(data: Data(source.utf8), format: .webVTT)
        XCTAssertEqual(document.cues.first?.startMilliseconds, 1_000)
        XCTAssertEqual(document.cues.first?.text, "Hello")
    }

    func testWebVTTRejectsEmptyAndMalformedCueBlocksButAllowsMetadataBlocks() throws {
        let parser = SubtitleParser()
        XCTAssertThrowsError(try parser.parse(data: Data("WEBVTT\n\n".utf8), format: .webVTT))

        let malformed = "WEBVTT\n\n00:00:01.000 --> invalid\nHello\n"
        XCTAssertThrowsError(try parser.parse(data: Data(malformed.utf8), format: .webVTT))

        let withMetadata = """
        WEBVTT

        NOTE generated locally
        This is metadata, not a cue.

        STYLE
        ::cue { color: white }

        cue-name
        00:00:01.000 --> 00:00:02.000 align:start
        Hello
        """
        let document = try parser.parse(data: Data(withMetadata.utf8), format: .webVTT)
        XCTAssertEqual(document.cues.count, 1)
        XCTAssertEqual(document.cues[0].id, 1)
        XCTAssertEqual(document.cues[0].text, "Hello")
    }
}
