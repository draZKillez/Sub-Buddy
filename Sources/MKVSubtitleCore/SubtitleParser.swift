import Foundation

enum SubtitleInternalFormat {
    static let assDialoguesMarker = "\u{001F}MKV_SUBTITLE_TRANSLATOR_DIALOGUES\u{001F}"
}

public struct SubtitleParser: Sendable {
    public init() {}

    public func parse(data: Data, format: SubtitleFormat) throws -> SubtitleDocument {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
            throw AppError.parsingFailed("文件不是可识别的 UTF-8/UTF-16 文本。")
        }
        // mkvextract commonly prefixes UTF-8 SRT files with a BOM. Swift keeps
        // it as U+FEFF, which would otherwise turn the first cue ID into
        // "\u{FEFF}1" and make the parser silently skip the entire first cue.
        while text.unicodeScalars.first?.value == 0xFEFF {
            text.removeFirst()
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch format {
        case .srt: return try parseSRT(text)
        case .ass: return try parseASS(text)
        case .webVTT: return try parseWebVTT(text)
        }
    }

    public func parse(contentsOf url: URL, format: SubtitleFormat) throws -> SubtitleDocument {
        try parse(data: Data(contentsOf: url), format: format)
    }

    private func parseSRT(_ text: String) throws -> SubtitleDocument {
        let normalizedBlankLines = text.replacingOccurrences(
            of: #"(?m)\n[ \t]*\n"#,
            with: "\n\n",
            options: .regularExpression
        )
        let normalized = normalizedBlankLines.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw AppError.parsingFailed("字幕文件为空，没有找到 SRT 时间轴。")
        }
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var seenIDs = Set<Int>()
        for (blockIndex, block) in blocks.enumerated() {
            var lines = block.components(separatedBy: "\n")
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
            guard lines.count >= 3,
                  let declaredID = Int(lines[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  declaredID > 0 else {
                throw AppError.parsingFailed("第 \(blockIndex + 1) 个 SRT 字幕块缺少数字序号、时间轴或正文。")
            }
            guard seenIDs.insert(declaredID).inserted else {
                throw AppError.parsingFailed("SRT 字幕 ID \(declaredID) 重复。")
            }
            guard let times = parseTimeline(lines[1], separator: "-->", parser: parseSRTTimestamp) else {
                throw AppError.parsingFailed("SRT 字幕 ID \(declaredID) 的时间轴无效。")
            }
            let body = lines[2...].joined(separator: "\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.parsingFailed("SRT 字幕 ID \(declaredID) 的正文为空。")
            }
            cues.append(SubtitleCue(
                id: declaredID,
                startMilliseconds: times.0,
                endMilliseconds: times.1,
                text: body
            ))
        }
        guard !cues.isEmpty else { throw AppError.parsingFailed("没有找到有效的 SRT 时间轴。") }
        return SubtitleDocument(format: .srt, cues: cues)
    }

    private func parseASS(_ text: String) throws -> SubtitleDocument {
        let lines = text.components(separatedBy: "\n")
        var inEvents = false
        var formatFields: [String] = []
        var headerLines: [String] = []
        var cues: [SubtitleCue] = []
        var insertedDialoguesMarker = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare("[Events]") == .orderedSame {
                inEvents = true
                headerLines.append(line)
                continue
            }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                inEvents = false
                headerLines.append(line)
                continue
            }
            if inEvents, trimmed.lowercased().hasPrefix("format:") {
                formatFields = trimmed.dropFirst("format:".count).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                headerLines.append(line)
                continue
            }
            if inEvents, trimmed.lowercased().hasPrefix("dialogue:") {
                guard !formatFields.isEmpty,
                      let startIndex = formatFields.firstIndex(of: "start"),
                      let endIndex = formatFields.firstIndex(of: "end"),
                      let textIndex = formatFields.firstIndex(of: "text") else {
                    throw AppError.parsingFailed("ASS/SSA Events Format 缺少 Start、End 或 Text 字段。")
                }
                let payload = String(trimmed.dropFirst("dialogue:".count)).trimmingCharacters(in: .whitespaces)
                let fields = splitASSDialogue(payload, fieldCount: formatFields.count, textIndex: textIndex)
                guard fields.count == formatFields.count,
                      let start = parseASSTimestamp(fields[startIndex]),
                      let end = parseASSTimestamp(fields[endIndex]),
                      end >= start else {
                    throw AppError.parsingFailed("第 \(cues.count + 1) 条 ASS/SSA Dialogue 的字段或时间轴无效。")
                }
                var preserved = fields
                let cueText = preserved.remove(at: textIndex)
                guard !cueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppError.parsingFailed("第 \(cues.count + 1) 条 ASS/SSA Dialogue 的正文为空。")
                }
                if !insertedDialoguesMarker {
                    headerLines.append(SubtitleInternalFormat.assDialoguesMarker)
                    insertedDialoguesMarker = true
                }
                cues.append(SubtitleCue(
                    id: cues.count + 1,
                    startMilliseconds: start,
                    endMilliseconds: end,
                    text: cueText,
                    assFields: preserved
                ))
            } else {
                headerLines.append(line)
            }
        }
        guard !cues.isEmpty else { throw AppError.parsingFailed("没有找到有效的 ASS/SSA Dialogue 字幕。") }
        return SubtitleDocument(
            format: .ass,
            cues: cues,
            assHeader: headerLines.joined(separator: "\n").trimmingCharacters(in: .newlines),
            assFormatFields: formatFields
        )
    }

    private func parseWebVTT(_ text: String) throws -> SubtitleDocument {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT") == true else {
            throw AppError.parsingFailed("缺少 WEBVTT 文件头。")
        }
        let header = lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var cues: [SubtitleCue] = []
        for (blockIndex, block) in body.components(separatedBy: "\n\n").enumerated() {
            let blockLines = block.components(separatedBy: "\n")
            let firstMeaningful = blockLines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if firstMeaningful.isEmpty || firstMeaningful == "STYLE" || firstMeaningful == "REGION" || firstMeaningful.hasPrefix("NOTE") {
                continue
            }
            guard let timelineIndex = blockLines.firstIndex(where: { $0.contains("-->") }),
                  let times = parseTimeline(blockLines[timelineIndex], separator: "-->", parser: parseVTTTimestamp) else {
                throw AppError.parsingFailed("第 \(blockIndex + 1) 个 WebVTT 字幕块缺少有效时间轴。")
            }
            let bodyStart = timelineIndex + 1
            let cueText = bodyStart < blockLines.count ? blockLines[bodyStart...].joined(separator: "\n") : ""
            guard !cueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AppError.parsingFailed("第 \(blockIndex + 1) 个 WebVTT 字幕块的正文为空。")
            }
            // WebVTT cue identifiers are arbitrary strings and are not required
            // to be unique. Translation state uses integer IDs, so assign a
            // deterministic, collision-free sequence for the generated SRT.
            cues.append(SubtitleCue(id: cues.count + 1, startMilliseconds: times.0, endMilliseconds: times.1, text: cueText))
        }
        guard !cues.isEmpty else { throw AppError.parsingFailed("没有找到有效的 WebVTT 时间轴。") }
        return SubtitleDocument(format: .webVTT, cues: cues, webVTTHeader: header)
    }

    private func parseTimeline(
        _ line: String,
        separator: String,
        parser: (String) -> Int64?
    ) -> (Int64, Int64)? {
        let parts = line.components(separatedBy: separator)
        guard parts.count == 2,
              let start = parser(parts[0].trimmingCharacters(in: .whitespaces)),
              let endToken = parts[1].split(separator: " ").first,
              let end = parser(String(endToken)) else { return nil }
        guard end >= start else { return nil }
        return (start, end)
    }

    private func parseSRTTimestamp(_ value: String) -> Int64? {
        parseClock(value.replacingOccurrences(of: ",", with: "."), fractionalScale: 1_000)
    }

    private func parseVTTTimestamp(_ value: String) -> Int64? {
        parseClock(value, fractionalScale: 1_000)
    }

    private func parseASSTimestamp(_ value: String) -> Int64? {
        parseClock(value, fractionalScale: 10)
    }

    private func parseClock(_ value: String, fractionalScale: Int64) -> Int64? {
        let mainParts = value.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard mainParts.count == 3,
              let hours = Int64(mainParts[0]), hours >= 0,
              let minutes = Int64(mainParts[1]), (0..<60).contains(minutes) else { return nil }
        let secondParts = mainParts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard secondParts.count <= 2,
              let seconds = Int64(secondParts[0]), (0..<60).contains(seconds) else { return nil }
        let fractionString = secondParts.count > 1 ? String(secondParts[1]) : "0"
        guard !fractionString.isEmpty, fractionString.allSatisfy(\.isNumber),
              let rawFraction = Int64(fractionString),
              hours <= Int64.max / 3_600_000 else { return nil }
        let fraction: Int64
        if fractionalScale == 10 {
            let padded = String((fractionString + "00").prefix(2))
            fraction = (Int64(padded) ?? rawFraction) * 10
        } else {
            let padded = String((fractionString + "000").prefix(3))
            fraction = Int64(padded) ?? 0
        }
        return ((hours * 3_600 + minutes * 60 + seconds) * 1_000) + fraction
    }

    /// ASS has no quoting syntax. The Text field can contain commas, so split
    /// fields before it from the left and fields after it from the right.
    private func splitASSDialogue(_ value: String, fieldCount: Int, textIndex: Int) -> [String] {
        guard fieldCount > 0, (0..<fieldCount).contains(textIndex) else { return [] }
        var prefix: [String] = []
        var remainder = value[...]
        for _ in 0..<textIndex {
            guard let comma = remainder.firstIndex(of: ",") else { return [] }
            prefix.append(String(remainder[..<comma]))
            remainder = remainder[remainder.index(after: comma)...]
        }

        var suffix: [String] = []
        for _ in 0..<(fieldCount - textIndex - 1) {
            guard let comma = remainder.lastIndex(of: ",") else { return [] }
            suffix.append(String(remainder[remainder.index(after: comma)...]))
            remainder = remainder[..<comma]
        }
        return prefix + [String(remainder)] + suffix.reversed()
    }
}
