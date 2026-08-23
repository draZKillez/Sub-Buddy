import XCTest
@testable import MKVSubtitleCore

final class PGSSubtitleDecoderTests: XCTestCase {
    func testDecodesSimpleBitmapAndPreservesDisplayTimeline() throws {
        var data = Data()
        appendPacket(type: 0x16, pts: 90_000, payload: composition(objectCount: 1), to: &data)
        appendPacket(type: 0x14, pts: 90_000, payload: [0, 0, 1, 235, 128, 128, 255], to: &data)
        // One 2x1 white object. Object data length includes four width/height bytes.
        appendPacket(type: 0x15, pts: 90_000, payload: [0, 1, 0, 0xC0, 0, 0, 8, 0, 2, 0, 1, 1, 1, 0, 0], to: &data)
        appendPacket(type: 0x80, pts: 90_000, payload: [], to: &data)
        appendPacket(type: 0x16, pts: 180_000, payload: composition(objectCount: 0), to: &data)
        appendPacket(type: 0x80, pts: 180_000, payload: [], to: &data)

        let cues = try PGSSubtitleDecoder().decode(data)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].startMilliseconds, 1_000)
        XCTAssertEqual(cues[0].endMilliseconds, 2_000)
        XCTAssertEqual(cues[0].width, 2)
        XCTAssertEqual(cues[0].height, 1)
        XCTAssertEqual(cues[0].rgba.count, 8)
        XCTAssertEqual(Array(cues[0].rgba)[3], 255)
    }

    func testRejectsTruncatedSUPPacket() {
        XCTAssertThrowsError(try PGSSubtitleDecoder().decode(Data([0x50, 0x47, 0, 0])))
    }

    func testOversizedBitmapDimensionsAreRejectedWithoutAllocation() throws {
        var data = Data()
        appendPacket(type: 0x16, pts: 90_000, payload: composition(objectCount: 1), to: &data)
        appendPacket(type: 0x14, pts: 90_000, payload: [0, 0, 1, 235, 128, 128, 255], to: &data)
        appendPacket(
            type: 0x15,
            pts: 90_000,
            payload: objectPayload(width: UInt16.max, height: UInt16.max, rle: [1, 0, 0]),
            to: &data
        )
        appendPacket(type: 0x80, pts: 90_000, payload: [], to: &data)
        appendPacket(type: 0x16, pts: 180_000, payload: composition(objectCount: 0), to: &data)

        XCTAssertEqual(try PGSSubtitleDecoder().decode(data), [])
    }

    func testTruncatedRLEObjectDoesNotProducePartiallyInitializedBitmap() throws {
        var data = Data()
        appendPacket(type: 0x16, pts: 90_000, payload: composition(objectCount: 1), to: &data)
        appendPacket(type: 0x14, pts: 90_000, payload: [0, 0, 1, 235, 128, 128, 255], to: &data)
        appendPacket(type: 0x15, pts: 90_000, payload: objectPayload(width: 2, height: 2, rle: [1]), to: &data)
        appendPacket(type: 0x80, pts: 90_000, payload: [], to: &data)
        appendPacket(type: 0x16, pts: 180_000, payload: composition(objectCount: 0), to: &data)

        XCTAssertEqual(try PGSSubtitleDecoder().decode(data), [])
    }

    private func composition(objectCount: UInt8) -> [UInt8] {
        var bytes: [UInt8] = [0x07, 0x80, 0x04, 0x38, 0x10, 0, 1, 0x80, 0, 0, objectCount]
        if objectCount > 0 {
            bytes += [0, 1, 0, 0, 0, 10, 0, 20]
        }
        return bytes
    }

    private func objectPayload(width: UInt16, height: UInt16, rle: [UInt8]) -> [UInt8] {
        let dataLength = rle.count + 4
        return [
            0, 1, 0, 0xC0,
            UInt8((dataLength >> 16) & 0xFF),
            UInt8((dataLength >> 8) & 0xFF),
            UInt8(dataLength & 0xFF),
            UInt8((width >> 8) & 0xFF), UInt8(width & 0xFF),
            UInt8((height >> 8) & 0xFF), UInt8(height & 0xFF)
        ] + rle
    }

    private func appendPacket(type: UInt8, pts: UInt32, payload: [UInt8], to data: inout Data) {
        data.append(contentsOf: [
            0x50, 0x47,
            UInt8((pts >> 24) & 0xFF), UInt8((pts >> 16) & 0xFF), UInt8((pts >> 8) & 0xFF), UInt8(pts & 0xFF),
            0, 0, 0, 0,
            type,
            UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)
        ])
        data.append(contentsOf: payload)
    }
}
