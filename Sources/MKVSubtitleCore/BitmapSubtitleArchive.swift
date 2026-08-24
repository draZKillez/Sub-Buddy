import Foundation

/// Decoder for the private, versioned archive emitted by the embedded
/// FFmpeg VobSub helper. It is deliberately small and strict: corrupt sizes
/// are rejected before allocating RGBA buffers.
public struct BitmapSubtitleArchive: Sendable {
    private static let magic = Data([0x4D, 0x4B, 0x56, 0x42, 0x4D, 0x30, 0x31, 0x00]) // MKVBM01\0
    private static let maximumDimension = 8_192
    private static let maximumPixels = 16_777_216
    #if os(iOS)
    private static let maximumArchiveBytes = 192 * 1_024 * 1_024
    #else
    private static let maximumArchiveBytes = 512 * 1_024 * 1_024
    #endif

    public init() {}

    public func decode(contentsOf url: URL) throws -> [PGSBitmapCue] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decode(data)
    }

    public func decode(_ data: Data) throws -> [PGSBitmapCue] {
        guard data.count <= Self.maximumArchiveBytes else {
            throw AppError.parsingFailed("位图字幕超过本设备的安全处理上限。")
        }
        guard data.count >= 12, data.prefix(8) == Self.magic else {
            throw AppError.parsingFailed("VobSub 位图归档格式无效。")
        }
        let count = Int(readUInt32(data, at: 8))
        guard count > 0, count <= 200_000 else {
            throw AppError.parsingFailed("VobSub 位图归档没有字幕或条目数异常。")
        }
        var offset = 12
        var cues: [PGSBitmapCue] = []
        cues.reserveCapacity(count)
        for _ in 0..<count {
            try Task.checkCancellation()
            guard offset <= data.count - 28 else { throw truncated() }
            let start = readInt64(data, at: offset)
            let end = readInt64(data, at: offset + 8)
            let width = Int(readUInt32(data, at: offset + 16))
            let height = Int(readUInt32(data, at: offset + 20))
            let byteCount = Int(readUInt32(data, at: offset + 24))
            offset += 28
            guard width > 0, height > 0,
                  width <= Self.maximumDimension, height <= Self.maximumDimension,
                  width <= Self.maximumPixels / height,
                  byteCount == width * height * 4,
                  byteCount <= data.count - offset,
                  end > start else {
                throw AppError.parsingFailed("VobSub 位图条目的尺寸或时间轴无效。")
            }
            cues.append(PGSBitmapCue(
                startMilliseconds: start,
                endMilliseconds: end,
                width: width,
                height: height,
                // Data slices retain the mapped archive storage without copying
                // every RGBA cue into a second allocation.
                rgba: data[offset..<(offset + byteCount)]
            ))
            offset += byteCount
        }
        guard offset == data.count else {
            throw AppError.parsingFailed("VobSub 位图归档包含多余或损坏的数据。")
        }
        return cues
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private func readInt64(_ data: Data, at offset: Int) -> Int64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(data[offset + index]) << UInt64(index * 8) }
        return Int64(bitPattern: value)
    }

    private func truncated() -> AppError {
        .parsingFailed("VobSub 位图归档被截断。")
    }
}
