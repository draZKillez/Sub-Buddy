import CoreGraphics
import Foundation
import Vision

public struct PGSBitmapCue: Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let width: Int
    public let height: Int
    public let rgba: Data

    public init(startMilliseconds: Int64, endMilliseconds: Int64, width: Int, height: Int, rgba: Data) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}

public struct PGSOCRResult: Sendable {
    public let document: SubtitleDocument
    public let lowConfidenceCueIDs: [Int]

    public init(document: SubtitleDocument, lowConfidenceCueIDs: [Int]) {
        self.document = document
        self.lowConfidenceCueIDs = lowConfidenceCueIDs
    }
}

public struct PGSSubtitleDecoder: Sendable {
    private static let maximumSUPBytes = 512 * 1_024 * 1_024
    private static let maximumBitmapDimension = 8_192
    private static let maximumBitmapPixels = 16_777_216
    #if os(iOS)
    private static let maximumDecodedBitmapBytes = 192 * 1_024 * 1_024
    #else
    private static let maximumDecodedBitmapBytes = 512 * 1_024 * 1_024
    #endif
    private struct Color: Equatable { let r: UInt8; let g: UInt8; let b: UInt8; let a: UInt8 }
    private struct ObjectBitmap { let width: Int; let height: Int; let indices: [UInt8] }
    private struct Assembly { var width = 0; var height = 0; var expectedBytes = 0; var bytes = Data() }
    private struct Placement { let objectID: UInt16; let x: Int; let y: Int }
    private struct Composition { let pts: UInt32; let paletteID: UInt8; let placements: [Placement] }
    private struct Rendered { let start: Int64; let width: Int; let height: Int; let rgba: Data }

    public init() {}

    public func decode(_ data: Data) throws -> [PGSBitmapCue] {
        guard data.count <= Self.maximumSUPBytes else {
            throw AppError.parsingFailed("PGS 字幕过大，超过当前版本 512 MB 的安全处理上限。")
        }
        if !data.isEmpty, data.count < 13 {
            throw AppError.parsingFailed("PGS 数据包被截断。")
        }
        // Data is random-access; do not duplicate the entire SUP into [UInt8].
        let bytes = data
        var offset = 0
        var palettes: [UInt8: [UInt8: Color]] = [:]
        var assemblies: [UInt16: Assembly] = [:]
        var objects: [UInt16: ObjectBitmap] = [:]
        var composition: Composition?
        var active: Rendered?
        var cues: [PGSBitmapCue] = []
        var decodedBitmapBytes = 0

        while offset + 13 <= bytes.count {
            if offset & 0x3FFFF == 0 { try Task.checkCancellation() }
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x47 else {
                throw AppError.parsingFailed("PGS 数据缺少 SUP 数据包头。")
            }
            let pts = readUInt32(bytes, offset + 2)
            let type = bytes[offset + 10]
            let length = Int(readUInt16(bytes, offset + 11))
            let start = offset + 13
            let end = start + length
            guard end <= bytes.count else { throw AppError.parsingFailed("PGS 数据包被截断。") }
            let payload = Array(bytes[start..<end])

            switch type {
            case 0x16:
                if let current = active, ptsMilliseconds(pts) > current.start {
                    decodedBitmapBytes += current.rgba.count
                    guard decodedBitmapBytes <= Self.maximumDecodedBitmapBytes else {
                        throw AppError.parsingFailed("PGS 解码后的字幕图片超过本设备的安全内存上限；请改用体积更小的字幕轨道。")
                    }
                    cues.append(PGSBitmapCue(
                        startMilliseconds: current.start,
                        endMilliseconds: ptsMilliseconds(pts),
                        width: current.width,
                        height: current.height,
                        rgba: current.rgba
                    ))
                    active = nil
                }
                composition = parseComposition(payload, pts: pts)
            case 0x14:
                if payload.count >= 2 {
                    let paletteID = payload[0]
                    var palette = palettes[paletteID] ?? [:]
                    var index = 2
                    while index + 4 < payload.count {
                        palette[payload[index]] = Self.rgba(
                            y: payload[index + 1],
                            cr: payload[index + 2],
                            cb: payload[index + 3],
                            alpha: payload[index + 4]
                        )
                        index += 5
                    }
                    palettes[paletteID] = palette
                }
            case 0x15:
                parseObject(payload, assemblies: &assemblies, objects: &objects)
            case 0x80:
                if let composition,
                   !composition.placements.isEmpty,
                   let rendered = render(composition, palette: palettes[composition.paletteID] ?? [:], objects: objects) {
                    active = rendered
                }
            default:
                break
            }
            offset = end
        }
        guard offset == bytes.count else {
            throw AppError.parsingFailed("PGS 文件末尾包含被截断的数据包。")
        }

        if let active {
            decodedBitmapBytes += active.rgba.count
            guard decodedBitmapBytes <= Self.maximumDecodedBitmapBytes else {
                throw AppError.parsingFailed("PGS 解码后的字幕图片超过本设备的安全内存上限；请改用体积更小的字幕轨道。")
            }
            cues.append(PGSBitmapCue(
                startMilliseconds: active.start,
                endMilliseconds: active.start + 5_000,
                width: active.width,
                height: active.height,
                rgba: active.rgba
            ))
        }
        return cues.filter { $0.endMilliseconds > $0.startMilliseconds && !$0.rgba.isEmpty }
    }

    private func parseComposition(_ bytes: [UInt8], pts: UInt32) -> Composition? {
        guard bytes.count >= 11 else { return nil }
        let paletteID = bytes[9]
        let count = Int(bytes[10])
        var offset = 11
        var placements: [Placement] = []
        for _ in 0..<count {
            guard offset + 7 < bytes.count else { break }
            let objectID = readUInt16(bytes, offset)
            let cropped = bytes[offset + 3] & 0x80 != 0
            placements.append(Placement(
                objectID: objectID,
                x: Int(readUInt16(bytes, offset + 4)),
                y: Int(readUInt16(bytes, offset + 6))
            ))
            offset += cropped ? 16 : 8
        }
        return Composition(pts: pts, paletteID: paletteID, placements: placements)
    }

    private func parseObject(
        _ bytes: [UInt8],
        assemblies: inout [UInt16: Assembly],
        objects: inout [UInt16: ObjectBitmap]
    ) {
        guard bytes.count >= 4 else { return }
        let objectID = readUInt16(bytes, 0)
        let sequence = bytes[3]
        var assembly: Assembly
        var payloadOffset: Int
        if sequence & 0x80 != 0 {
            guard bytes.count >= 11 else { return }
            let dataLength = Int(bytes[4]) << 16 | Int(bytes[5]) << 8 | Int(bytes[6])
            assembly = Assembly(
                width: Int(readUInt16(bytes, 7)),
                height: Int(readUInt16(bytes, 9)),
                expectedBytes: max(0, dataLength - 4),
                bytes: Data()
            )
            payloadOffset = 11
        } else {
            guard let existing = assemblies[objectID] else { return }
            assembly = existing
            payloadOffset = 4
        }
        if payloadOffset < bytes.count { assembly.bytes.append(contentsOf: bytes[payloadOffset...]) }
        assemblies[objectID] = assembly
        if sequence & 0x40 != 0 || assembly.bytes.count >= assembly.expectedBytes {
            if let indices = decodeRLE([UInt8](assembly.bytes), width: assembly.width, height: assembly.height) {
                objects[objectID] = ObjectBitmap(width: assembly.width, height: assembly.height, indices: indices)
            }
            assemblies[objectID] = nil
        }
    }

    private func decodeRLE(_ bytes: [UInt8], width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0,
              width <= Self.maximumBitmapDimension,
              height <= Self.maximumBitmapDimension,
              width <= Self.maximumBitmapPixels / height else { return nil }
        var output = [UInt8](repeating: 0, count: width * height)
        var source = 0
        var x = 0
        var y = 0
        while source < bytes.count, y < height {
            let first = bytes[source]
            source += 1
            if first != 0 {
                if x < width { output[y * width + x] = first }
                x += 1
                continue
            }
            guard source < bytes.count else { break }
            let control = bytes[source]
            source += 1
            if control == 0 {
                y += 1
                x = 0
                continue
            }
            var run: Int
            var color: UInt8 = 0
            if control & 0x40 != 0 {
                guard source < bytes.count else { break }
                run = (Int(control & 0x3F) << 8) | Int(bytes[source])
                source += 1
            } else {
                run = Int(control & 0x3F)
            }
            if control & 0x80 != 0 {
                guard source < bytes.count else { break }
                color = bytes[source]
                source += 1
            }
            for _ in 0..<run {
                guard y < height else { break }
                if x >= width { y += 1; x = 0; if y >= height { break } }
                output[y * width + x] = color
                x += 1
            }
        }
        guard y >= height || (y == height - 1 && x >= width) else { return nil }
        return output
    }

    private func render(
        _ composition: Composition,
        palette: [UInt8: Color],
        objects: [UInt16: ObjectBitmap]
    ) -> Rendered? {
        let available = composition.placements.compactMap { placement -> (Placement, ObjectBitmap)? in
            objects[placement.objectID].map { (placement, $0) }
        }
        guard !available.isEmpty else { return nil }
        let minX = available.map { $0.0.x }.min() ?? 0
        let minY = available.map { $0.0.y }.min() ?? 0
        let maxX = available.map { $0.0.x + $0.1.width }.max() ?? minX
        let maxY = available.map { $0.0.y + $0.1.height }.max() ?? minY
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0,
              width <= Self.maximumBitmapDimension,
              height <= Self.maximumBitmapDimension,
              width <= Self.maximumBitmapPixels / height else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (placement, object) in available {
            for row in 0..<object.height {
                for column in 0..<object.width {
                    let color = palette[object.indices[row * object.width + column]] ?? Color(r: 0, g: 0, b: 0, a: 0)
                    let x = placement.x - minX + column
                    let y = placement.y - minY + row
                    let target = (y * width + x) * 4
                    rgba[target] = color.r
                    rgba[target + 1] = color.g
                    rgba[target + 2] = color.b
                    rgba[target + 3] = color.a
                }
            }
        }
        return Rendered(start: ptsMilliseconds(composition.pts), width: width, height: height, rgba: Data(rgba))
    }

    private static func rgba(y: UInt8, cr: UInt8, cb: UInt8, alpha: UInt8) -> Color {
        let yy = Double(y)
        let red = yy + 1.402 * (Double(cr) - 128)
        let green = yy - 0.344_136 * (Double(cb) - 128) - 0.714_136 * (Double(cr) - 128)
        let blue = yy + 1.772 * (Double(cb) - 128)
        func channel(_ value: Double) -> UInt8 { UInt8(max(0, min(255, Int(value.rounded())))) }
        return Color(r: channel(red), g: channel(green), b: channel(blue), a: alpha)
    }

    private func ptsMilliseconds(_ pts: UInt32) -> Int64 { Int64(pts) * 1_000 / 90_000 }
    private func readUInt16<C: RandomAccessCollection>(_ bytes: C, _ offset: Int) -> UInt16 where C.Element == UInt8, C.Index == Int {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }
    private func readUInt32<C: RandomAccessCollection>(_ bytes: C, _ offset: Int) -> UInt32 where C.Element == UInt8, C.Index == Int {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

public final class LocalPGSOCRService: @unchecked Sendable {
    public init() {}

    public func recognize(
        supURL: URL,
        language: String,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> PGSOCRResult {
        let worker = Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: supURL, options: [.mappedIfSafe])
            try Task.checkCancellation()
            let bitmapCues = try PGSSubtitleDecoder().decode(data)
            return try await Self.recognize(bitmapCues: bitmapCues, language: language, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func recognize(
        bitmapArchiveURL: URL,
        language: String,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> PGSOCRResult {
        let worker = Task.detached(priority: .userInitiated) {
            let bitmapCues = try BitmapSubtitleArchive().decode(contentsOf: bitmapArchiveURL)
            return try await Self.recognize(bitmapCues: bitmapCues, language: language, progress: progress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func recognize(
        bitmapCues input: [PGSBitmapCue],
        language: String,
        progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
    ) async throws -> PGSOCRResult {
        try Task.checkCancellation()
        guard !input.isEmpty else { throw AppError.parsingFailed("图片字幕中没有找到可识别的图片。") }
        var bitmapCues = input.map(Optional.some)
        let totalCueCount = bitmapCues.count
        #if os(iOS)
        let parallelism = max(1, min(3, ProcessInfo.processInfo.activeProcessorCount / 2))
        #else
        let parallelism = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount / 2))
        #endif
        var results = [Int: (SubtitleCue, Bool)]()
        var completed = 0
        var lastProgressUpdate = ContinuousClock.now
        try await withThrowingTaskGroup(of: (Int, SubtitleCue, Bool).self) { group in
            var nextIndex = 0
            func add(_ index: Int) {
                guard let bitmap = bitmapCues[index] else { return }
                bitmapCues[index] = nil
                group.addTask {
                    try Task.checkCancellation()
                    let recognized = try Self.recognize(bitmap, language: language)
                    let id = index + 1
                    let text = recognized.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let low = recognized.confidence < 0.65 || text.isEmpty
                    return (id, SubtitleCue(
                        id: id,
                        startMilliseconds: bitmap.startMilliseconds,
                        endMilliseconds: bitmap.endMilliseconds,
                        text: text.isEmpty ? "[OCR 未能识别，请人工校对]" : text
                    ), low)
                }
            }
            while nextIndex < min(parallelism, totalCueCount) { add(nextIndex); nextIndex += 1 }
            while let (id, cue, low) = try await group.next() {
                results[id] = (cue, low)
                completed += 1
                let now = ContinuousClock.now
                if completed == totalCueCount || now - lastProgressUpdate >= .milliseconds(100) {
                    progress(completed, totalCueCount)
                    lastProgressUpdate = now
                }
                if nextIndex < totalCueCount { add(nextIndex); nextIndex += 1 }
            }
        }
        let ordered = (1...totalCueCount).compactMap { results[$0]?.0 }
        let lowConfidence = (1...totalCueCount).filter { results[$0]?.1 == true }
        return PGSOCRResult(
            document: SubtitleDocument(format: .srt, cues: ordered),
            lowConfidenceCueIDs: lowConfidence
        )
    }

    private static func recognize(_ cue: PGSBitmapCue, language: String) throws -> (text: String, confidence: Float) {
        // Vision internally creates a bi-planar pixel buffer for recognition;
        // that format requires even dimensions. PGS objects frequently have
        // odd sizes (for example 737×73), so transparently pad one row/column.
        let imageWidth = ((cue.width + 15) / 16) * 16
        let imageHeight = ((cue.height + 15) / 16) * 16
        var padded = Data(repeating: 0, count: imageWidth * imageHeight * 4)
        padded.withUnsafeMutableBytes { destination in
            cue.rgba.withUnsafeBytes { source in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = source.baseAddress else { return }
                for row in 0..<cue.height {
                    destinationBase.advanced(by: row * imageWidth * 4).copyMemory(
                        from: sourceBase.advanced(by: row * cue.width * 4),
                        byteCount: cue.width * 4
                    )
                }
            }
        }
        let bytesPerRow = imageWidth * 4
        guard let provider = CGDataProvider(data: padded as CFData),
              let image = CGImage(
                width: imageWidth,
                height: imageHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else { throw AppError.parsingFailed("无法生成图片字幕画面。") }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let requestedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveLanguage = requestedLanguage.isEmpty || requestedLanguage == "und" ? "en-US" : requestedLanguage
        let supported = try request.supportedRecognitionLanguages()
        guard supported.contains(effectiveLanguage) else {
            throw AppError.unsupportedSubtitle("当前系统的 Apple Vision OCR 不支持 \(effectiveLanguage)。请选择其他原文语言或文本字幕轨道。")
        }
        request.recognitionLanguages = [effectiveLanguage]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).sorted {
            if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.03 { return $0.boundingBox.midY > $1.boundingBox.midY }
            return $0.boundingBox.minX < $1.boundingBox.minX
        }
        let candidates = observations.compactMap { $0.topCandidates(1).first }
        let text = candidates.map(\.string).joined(separator: "\n")
        let confidence = candidates.isEmpty ? 0 : candidates.reduce(0) { $0 + $1.confidence } / Float(candidates.count)
        return (text, confidence)
    }
}
