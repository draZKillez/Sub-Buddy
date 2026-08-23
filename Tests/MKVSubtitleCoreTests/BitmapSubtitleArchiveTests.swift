import Foundation
import XCTest
@testable import MKVSubtitleCore

final class BitmapSubtitleArchiveTests: XCTestCase {
    func testDecodesCueAndPreservesTimelineAndRGBA() throws {
        var data = Data("MKVBM01\0".utf8)
        append(UInt32(1), to: &data)
        append(Int64(1_250), to: &data)
        append(Int64(4_750), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(1), to: &data)
        append(UInt32(8), to: &data)
        data.append(contentsOf: [255, 255, 255, 255, 0, 0, 0, 0])

        let cues = try BitmapSubtitleArchive().decode(data)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startMilliseconds, 1_250)
        XCTAssertEqual(cues[0].endMilliseconds, 4_750)
        XCTAssertEqual(cues[0].width, 2)
        XCTAssertEqual(cues[0].rgba, Data([255, 255, 255, 255, 0, 0, 0, 0]))
    }

    func testRejectsTruncatedAndDimensionMismatch() throws {
        XCTAssertThrowsError(try BitmapSubtitleArchive().decode(Data("MKVBM01\0".utf8)))

        var data = Data("MKVBM01\0".utf8)
        append(UInt32(1), to: &data)
        append(Int64(0), to: &data)
        append(Int64(1_000), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(2), to: &data)
        append(UInt32(4), to: &data)
        data.append(contentsOf: [0, 0, 0, 0])
        XCTAssertThrowsError(try BitmapSubtitleArchive().decode(data))
    }

    func testVobSubTrackIsLocallyProcessable() {
        let track = SubtitleTrack(
            streamIndex: 2, codec: "dvd_subtitle", language: "eng", title: "",
            isDefault: false, isForced: false, isSDH: false, isText: false
        )
        XCTAssertTrue(track.supportsLocalOCR)
        XCTAssertTrue(track.isVobSub)
        XCTAssertTrue(track.isProcessable)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    private func append(_ value: Int64, to data: inout Data) {
        let raw = UInt64(bitPattern: value)
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8(truncatingIfNeeded: raw >> UInt64(shift))) }
    }
}
